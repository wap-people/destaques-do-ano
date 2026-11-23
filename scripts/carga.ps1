# Teste de carga SEM instalar nada (PowerShell + .NET do Windows).
# SÓ contra a HOMOLOGAÇÃO com a base sintética (supabase/tests/02_sinteticos.sql) e a votação aberta.
#
#   powershell -ExecutionPolicy Bypass -File scripts/carga.ps1 -Url https://xxx.supabase.co -Key <anon> [-Eleitores 1000] [-RampaSeg 120]
#
# Cada eleitor virtual: identifica-se, "pensa" 1-4 s, envia a cédula com 0-3 escolhas por categoria.
# 5% repetem o envio de propósito (tem que ser recusado). Critérios: 0 erros, p95 < 2 s.
param(
  [Parameter(Mandatory)] [string]$Url,
  [Parameter(Mandatory)] [string]$Key,
  [int]$Eleitores = 1000,
  [int]$RampaSeg = 120,
  [int]$Primeiro = 2
)

$cs = @'
using System; using System.Collections; using System.Collections.Generic; using System.Collections.Concurrent;
using System.Diagnostics; using System.Linq; using System.Net; using System.Net.Http; using System.Text;
using System.Threading; using System.Threading.Tasks; using System.Web.Script.Serialization;

public static class Carga {
  static HttpClient http; static string U, K;
  public static ConcurrentBag<double> TIni = new ConcurrentBag<double>(), TReg = new ConcurrentBag<double>();
  public static int Ok, RecusaIni, RecusaReg, Erros, DuplosRecusados, DuplosAceitos, Indicacoes, Pico, Ativos;
  public static ConcurrentBag<string> Msgs = new ConcurrentBag<string>();

  public static string Cpf(int i) {
    var b = (900000000 + i).ToString().Select(c => c - '0').ToList();
    Func<List<int>, int, int> dv = (a, p) => { int s = 0; for (int k = 0; k < a.Count; k++) s += a[k] * (p - k); int r = (s * 10) % 11; return r == 10 ? 0 : r; };
    b.Add(dv(b, 10)); b.Add(dv(b, 11));
    return string.Concat(b);
  }
  public static string Nasc(int i) { return new DateTime(1970, 1, 1).AddDays(i * 37 % 12000).ToString("yyyy-MM-dd"); }

  static async Task<Tuple<double, Dictionary<string, object>>> Rpc(string f, string body) {
    var sw = Stopwatch.StartNew();
    var req = new HttpRequestMessage(HttpMethod.Post, U + "/rest/v1/rpc/" + f);
    req.Headers.Add("apikey", K); req.Headers.Add("Authorization", "Bearer " + K);
    req.Content = new StringContent(body, Encoding.UTF8, "application/json");
    var resp = await http.SendAsync(req);
    var txt = await resp.Content.ReadAsStringAsync();
    sw.Stop();
    if (!resp.IsSuccessStatusCode) throw new Exception(f + " HTTP " + (int)resp.StatusCode + " " + txt.Substring(0, Math.Min(160, txt.Length)));
    var js = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
    return Tuple.Create(sw.Elapsed.TotalMilliseconds, js.Deserialize<Dictionary<string, object>>(txt));
  }

  static async Task Eleitor(int i, int atrasoMs) {
    var rnd = new Random(i * 7919);
    await Task.Delay(atrasoMs);
    int a = Interlocked.Increment(ref Ativos); int p; while ((p = Pico) < a && Interlocked.CompareExchange(ref Pico, a, p) != p) { }
    try {
      var js = new JavaScriptSerializer();
      var r1 = await Rpc("iniciar_votacao", js.Serialize(new Dictionary<string, object> { { "p_cpf", Cpf(i) }, { "p_nascimento", Nasc(i) } }));
      TIni.Add(r1.Item1);
      var d = r1.Item2;
      if (!(d.ContainsKey("ok") && (bool)d["ok"])) { Interlocked.Increment(ref RecusaIni); Msgs.Add("iniciar " + i + ": " + d["mensagem"]); return; }
      await Task.Delay(rnd.Next(1000, 4000));
      var pessoas = (ArrayList)d["pessoas"]; var cats = (ArrayList)d["categorias"];
      var esc = new Dictionary<string, object>(); int total = 0;
      foreach (Dictionary<string, object> c in cats) {
        var cand = (ArrayList)c["candidatos"]; int n = Math.Min(cand.Count, rnd.Next(0, 4));
        var set = new HashSet<string>(); int guard = 0;
        while (set.Count < n && guard++ < 50) set.Add((string)((ArrayList)pessoas[(int)cand[rnd.Next(cand.Count)]])[0]);
        esc[(string)c["codigo"]] = set.ToList(); total += set.Count;
      }
      if (total == 0) foreach (Dictionary<string, object> c in cats) {
        var cand = (ArrayList)c["candidatos"];
        if (cand.Count > 0) { esc[(string)c["codigo"]] = new List<string> { (string)((ArrayList)pessoas[(int)cand[0]])[0] }; total = 1; break; }
      }
      var body = js.Serialize(new Dictionary<string, object> { { "p_token", d["token"] }, { "p_escolhas", esc } });
      var r2 = await Rpc("registrar_cedula", body);
      TReg.Add(r2.Item1);
      if (r2.Item2.ContainsKey("ok") && (bool)r2.Item2["ok"]) { Interlocked.Increment(ref Ok); Interlocked.Add(ref Indicacoes, total); }
      else { Interlocked.Increment(ref RecusaReg); Msgs.Add("registrar " + i + ": " + r2.Item2["mensagem"]); }
      if (rnd.NextDouble() < 0.05) {
        var r3 = await Rpc("registrar_cedula", body);
        if ((bool)r3.Item2["ok"]) Interlocked.Increment(ref DuplosAceitos); else Interlocked.Increment(ref DuplosRecusados);
      }
    } catch (Exception e) { Interlocked.Increment(ref Erros); Msgs.Add("ERRO " + i + ": " + e.Message); }
    finally { Interlocked.Decrement(ref Ativos); }
  }

  public static void Rodar(string url, string key, int[] ids, int rampaSeg) {
    U = url.TrimEnd('/'); K = key;
    ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
    ServicePointManager.DefaultConnectionLimit = 2000;
    http = new HttpClient { Timeout = TimeSpan.FromSeconds(60) };
    var tasks = new List<Task>();
    for (int k = 0; k < ids.Length; k++) tasks.Add(Eleitor(ids[k], (int)((double)k / ids.Length * rampaSeg * 1000)));
    Task.WaitAll(tasks.ToArray());
  }
  public static double P(ConcurrentBag<double> b, double q) {
    var a = b.OrderBy(x => x).ToArray(); if (a.Length == 0) return 0;
    return a[Math.Max(0, Math.Min(a.Length - 1, (int)Math.Ceiling(q * a.Length) - 1))];
  }
}
'@
Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Net.Http, System.Web.Extensions, System.Core, System.Collections.Concurrent -ErrorAction Stop

$ids = @(); $i = $Primeiro
while ($ids.Count -lt $Eleitores -and $i -le 1100) { if ($i % 40 -ne 0) { $ids += $i }; $i++ }
Write-Host "Eleitores virtuais: $($ids.Count) · rampa de $RampaSeg s · alvo: $Url"
$sw = [Diagnostics.Stopwatch]::StartNew()
[Carga]::Rodar($Url, $Key, [int[]]$ids, $RampaSeg)
$sw.Stop()

$res = [ordered]@{
  duracao_s            = [math]::Round($sw.Elapsed.TotalSeconds, 1)
  eleitores            = $ids.Count
  pico_simultaneos     = [Carga]::Pico
  cedulas_ok           = [Carga]::Ok
  indicacoes_enviadas  = [Carga]::Indicacoes
  recusas_iniciar      = [Carga]::RecusaIni
  recusas_registrar    = [Carga]::RecusaReg
  erros_http           = [Carga]::Erros
  duplos_recusados     = [Carga]::DuplosRecusados
  duplos_ACEITOS       = [Carga]::DuplosAceitos
  iniciar_p50_ms       = [math]::Round([Carga]::P([Carga]::TIni, 0.50))
  iniciar_p95_ms       = [math]::Round([Carga]::P([Carga]::TIni, 0.95))
  iniciar_max_ms       = [math]::Round([Carga]::P([Carga]::TIni, 1.0))
  registrar_p50_ms     = [math]::Round([Carga]::P([Carga]::TReg, 0.50))
  registrar_p95_ms     = [math]::Round([Carga]::P([Carga]::TReg, 0.95))
  registrar_max_ms     = [math]::Round([Carga]::P([Carga]::TReg, 1.0))
}
$res | Format-Table -AutoSize | Out-String | Write-Host
[Carga]::Msgs | Select-Object -First 15 | ForEach-Object { Write-Host $_ }
$ok = ([Carga]::Erros -eq 0) -and ([Carga]::DuplosAceitos -eq 0) -and ([Carga]::RecusaIni -eq 0) -and ([Carga]::RecusaReg -eq 0) -and ($res.iniciar_p95_ms -lt 2000) -and ($res.registrar_p95_ms -lt 2000)
Write-Host $(if ($ok) { 'RESULTADO: APROVADO' } else { 'RESULTADO: REPROVADO' })
Write-Host "Confira no banco: cédulas = $([Carga]::Ok) (+ as que já existiam) e votos = $([Carga]::Indicacoes) (+ os que já existiam)."
