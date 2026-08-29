param(
    [int]$Port = 0
)

$ErrorActionPreference = "Stop"
$Root = (Resolve-Path $PSScriptRoot).Path
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse("127.0.0.1"), $Port)
$listener.Start()
$actualPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port

# Open the game in the user's default browser.
Start-Process ("http://127.0.0.1:{0}/index.html" -f $actualPort)

$mime = @{
    ".html"="text/html; charset=utf-8"
    ".htm"="text/html; charset=utf-8"
    ".css"="text/css; charset=utf-8"
    ".js"="application/javascript; charset=utf-8"
    ".json"="application/json; charset=utf-8"
    ".txt"="text/plain; charset=utf-8"
    ".png"="image/png"
    ".jpg"="image/jpeg"
    ".jpeg"="image/jpeg"
    ".gif"="image/gif"
    ".webp"="image/webp"
    ".svg"="image/svg+xml"
    ".mp3"="audio/mpeg"
    ".wav"="audio/wav"
    ".ogg"="audio/ogg"
    ".mp4"="video/mp4"
    ".webm"="video/webm"
    ".ico"="image/x-icon"
}

function Send-Bytes($stream, [byte[]]$bytes, $status, $contentType, $extraHeaders=@{}) {
    $header = "HTTP/1.1 $status`r`n"
    $header += "Content-Type: $contentType`r`n"
    $header += "Content-Length: $($bytes.Length)`r`n"
    $header += "Cache-Control: no-cache`r`n"
    $header += "Connection: close`r`n"
    foreach ($key in $extraHeaders.Keys) { $header += "$key`: $($extraHeaders[$key])`r`n" }
    $header += "`r`n"
    $hb = [Text.Encoding]::ASCII.GetBytes($header)
    $stream.Write($hb,0,$hb.Length)
    if ($bytes.Length -gt 0) { $stream.Write($bytes,0,$bytes.Length) }
}

# Keep the local server alive for up to 2 hours, enough for a normal play session.
$deadline = (Get-Date).AddHours(2)

try {
    while ((Get-Date) -lt $deadline) {
        if (-not $listener.Pending()) {
            Start-Sleep -Milliseconds 80
            continue
        }

        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 5000
            $buffer = New-Object byte[] 16384
            $count = $stream.Read($buffer,0,$buffer.Length)
            if ($count -le 0) { $client.Close(); continue }

            $request = [Text.Encoding]::ASCII.GetString($buffer,0,$count)
            $firstLine = ($request -split "`r?`n")[0]
            if ($firstLine -notmatch '^(GET|HEAD)\s+(\S+)\s+HTTP/') {
                Send-Bytes $stream ([byte[]]@()) "405 Method Not Allowed" "text/plain"
                $client.Close(); continue
            }

            $method = $Matches[1]
            $rawPath = $Matches[2]
            $rawPath = $rawPath -split '\?' | Select-Object -First 1
            $decoded = [Uri]::UnescapeDataString($rawPath)
            if ([string]::IsNullOrWhiteSpace($decoded) -or $decoded -eq "/") { $decoded = "/index.html" }

            # Basic traversal protection.
            $relative = $decoded.TrimStart("/") -replace '/', [IO.Path]::DirectorySeparatorChar
            $full = [IO.Path]::GetFullPath((Join-Path $Root $relative))
            if (-not $full.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) {
                Send-Bytes $stream ([Text.Encoding]::UTF8.GetBytes("Forbidden")) "403 Forbidden" "text/plain; charset=utf-8"
                $client.Close(); continue
            }

            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
                Send-Bytes $stream ([Text.Encoding]::UTF8.GetBytes("Not Found")) "404 Not Found" "text/plain; charset=utf-8"
                $client.Close(); continue
            }

            $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
            $contentType = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { "application/octet-stream" }
            $bytes = [IO.File]::ReadAllBytes($full)

            # Support HTTP byte ranges, useful for browser audio playback.
            $rangeHeader = ($request -split "`r?`n" | Where-Object { $_ -match '^Range:\s*bytes=' } | Select-Object -First 1)
            if ($rangeHeader -and $rangeHeader -match 'bytes=(\d*)-(\d*)') {
                $start = 0
                $end = $bytes.Length - 1
                if ($Matches[1] -ne "") { $start = [int64]$Matches[1] }
                if ($Matches[2] -ne "") { $end = [int64]$Matches[2] }
                if ($start -gt $end -or $start -ge $bytes.Length) {
                    Send-Bytes $stream ([byte[]]@()) "416 Range Not Satisfiable" $contentType @{"Content-Range"="bytes */$($bytes.Length)"}
                } else {
                    if ($end -ge $bytes.Length) { $end = $bytes.Length - 1 }
                    $length = [int]($end - $start + 1)
                    $part = New-Object byte[] $length
                    [Array]::Copy($bytes, [int]$start, $part, 0, $length)
                    $extra = @{"Accept-Ranges"="bytes"; "Content-Range"="bytes $start-$end/$($bytes.Length)"}
                    if ($method -eq "HEAD") { $part = [byte[]]@() }
                    Send-Bytes $stream $part "206 Partial Content" $contentType $extra
                }
            } else {
                if ($method -eq "HEAD") { $bytes = [byte[]]@() }
                Send-Bytes $stream $bytes "200 OK" $contentType @{"Accept-Ranges"="bytes"}
            }
        } catch {
            try {
                Send-Bytes $stream ([Text.Encoding]::UTF8.GetBytes("Server error")) "500 Internal Server Error" "text/plain; charset=utf-8"
            } catch {}
        } finally {
            try { $stream.Close() } catch {}
            try { $client.Close() } catch {}
        }
    }
} finally {
    $listener.Stop()
}
