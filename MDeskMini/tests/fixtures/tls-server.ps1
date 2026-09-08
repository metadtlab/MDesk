$ErrorActionPreference = 'Stop'
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
$request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
    'CN=localhost', $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
$san = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
$san.AddIpAddress([System.Net.IPAddress]::Loopback)
$request.CertificateExtensions.Add($san.Build())
$certificate = $request.CreateSelfSigned([DateTimeOffset]::Now.AddMinutes(-1), [DateTimeOffset]::Now.AddMinutes(5))
$tlsCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
    $certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx),
    '', [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::DefaultKeySet)
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
try {
    [Console]::WriteLine($listener.LocalEndpoint.Port)
    [Console]::Out.Flush()
    $accept = $listener.AcceptTcpClientAsync()
    if (-not $accept.Wait(15000)) { throw 'No test connection' }
    $client = $accept.Result
    $stream = [System.Net.Security.SslStream]::new($client.GetStream(), $false)
    $stream.ReadTimeout = 10000
    $stream.WriteTimeout = 10000
    try {
        $stream.AuthenticateAsServer($tlsCertificate, $false, [System.Security.Authentication.SslProtocols]::Tls12, $false)
        $body = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 2`r`nConnection: close`r`n`r`nOK")
        $stream.Write($body)
    } catch {
        # Certificate rejection by the client is expected; it must not send secrets.
        [Console]::Error.WriteLine($_.Exception.Message)
    } finally {
        $stream.Dispose()
        $client.Dispose()
    }
} finally {
    $listener.Stop()
    $certificate.Dispose()
    $tlsCertificate.Dispose()
    $rsa.Dispose()
}
