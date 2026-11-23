# Servidor estático local para testar o site (só localhost).
#   powershell -ExecutionPolicy Bypass -File scripts/servidor-local.ps1 [-Porta 8080]
param([int]$Porta = 8080)
$raiz = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$tipos = @{ '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.mjs' = 'text/javascript; charset=utf-8';
  '.css' = 'text/css; charset=utf-8'; '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.json' = 'application/json'; '.ico' = 'image/x-icon'; '.pdf' = 'application/pdf'; '.webp' = 'image/webp' }
$l = New-Object System.Net.HttpListener
$l.Prefixes.Add("http://localhost:$Porta/")
$l.Start()
Write-Host "Servindo $raiz em http://localhost:$Porta/"
while ($l.IsListening) {
  $ctx = $l.GetContext()
  try {
    $rel = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath.TrimStart('/'))
    if ($rel -eq '') { $rel = 'index.html' }
    $arq = [IO.Path]::GetFullPath((Join-Path $raiz $rel))
    if (-not $arq.StartsWith($raiz) -or -not (Test-Path $arq -PathType Leaf)) {
      $ctx.Response.StatusCode = 404; $b = [Text.Encoding]::UTF8.GetBytes('404')
    } else {
      $ext = [IO.Path]::GetExtension($arq).ToLower()
      $ctx.Response.ContentType = $(if ($tipos[$ext]) { $tipos[$ext] } else { 'application/octet-stream' })
      $ctx.Response.Headers.Add('Cache-Control', 'no-store')
      $b = [IO.File]::ReadAllBytes($arq)
    }
    $ctx.Response.OutputStream.Write($b, 0, $b.Length)
  } catch { } finally { $ctx.Response.Close() }
}
