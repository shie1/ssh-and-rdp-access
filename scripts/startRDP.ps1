param(
	[string]$BaseUrl = "!<<ENV_BASE_URL>>",
	[string]$Target = "!<<ENV_TARGET>>",
	[int]$TargetPort = "!<<ENV_TARGET_PORT>>",
	[int]$RDPPort = "!<<ENV_RDP_PORT>>",
	[string]$RemoteCommand = ""
)

$ErrorActionPreference = "Stop"

function ConvertTo-PlainText {
	param([System.Security.SecureString]$SecureValue)

	if (-not $SecureValue) {
		return ""
	}

	$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
	try {
		return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
	}
	finally {
		[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
	}
}

function Cleanup-KeyFile {
	param([string]$Path)

	if ([string]::IsNullOrWhiteSpace($Path)) {
		return
	}

	if (Test-Path -LiteralPath $Path) {
		try {
			[System.IO.File]::Delete($Path)
		}
		catch {
		}
	}
}

function Wait-ForLocalPort {
	param(
		[int]$Port,
		[int]$TimeoutSeconds = 15
	)

	$deadline = (Get-Date).AddSeconds($TimeoutSeconds)

	while ((Get-Date) -lt $deadline) {
		if ($sshProcess -and $sshProcess.HasExited) {
			throw "Az SSH alagut megszakadt mielott az RDP port elerhetove valt."
		}

		$client = $null
		try {
			$client = New-Object System.Net.Sockets.TcpClient
			$asyncResult = $client.BeginConnect("127.0.0.1", $Port, $null, $null)

			if ($asyncResult.AsyncWaitHandle.WaitOne(250)) {
				$client.EndConnect($asyncResult)
				return
			}
		}
		catch {
		}
		finally {
			if ($client) {
				$client.Close()
			}
		}

		Start-Sleep -Milliseconds 250
	}

	throw "Az SSH alagut nem valt elerhetove idoben."
}

function Get-FreeLocalPort {
	$listener = $null
	try {
		$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
		$listener.Start()
		return (($listener.LocalEndpoint).Port)
	}
	finally {
		if ($listener) {
			$listener.Stop()
		}
	}
}

$normalizedBase = $BaseUrl.TrimEnd("/")
$keyEndpoint = "$normalizedBase/key"

$passwordSecure = Read-Host "Jelszo" -AsSecureString
$password = ConvertTo-PlainText -SecureValue $passwordSecure

if ([string]::IsNullOrWhiteSpace($password)) {
	throw "A jelszo nem lehet ures."
}

$otp = Read-Host "2FA kod (6 szamjegy)"

if ($otp -notmatch "^\d{6}$") {
	throw "A 2FA kodnak pontosan 6 szamjegynek kell lennie."
}

$authHeader = "Bearer $password`:$otp"

if (-not [string]::IsNullOrWhiteSpace($RemoteCommand)) {
	throw "Az RDP inditashoz nem tamogatott a RemoteCommand paramter."
}

$privateKey = $null
$tempKeyPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("ssh-key-{0}.pem" -f ([Guid]::NewGuid().ToString("N")))
$localForwardPort = Get-FreeLocalPort

$sshProcess = $null

try {
	Write-Host "SSH kulcs letoltese..."

	$privateKey = (Invoke-WebRequest `
		-Uri $keyEndpoint `
		-Method Get `
		-Headers @{ Authorization = $authHeader } `
		-UseBasicParsing).Content

	if ([string]::IsNullOrWhiteSpace($privateKey)) {
		throw "Ures SSH kulcs erkezett a szervertol."
	}

	Set-Content -LiteralPath $tempKeyPath -Value $privateKey -NoNewline -Encoding ascii

	$sshExecutable = (Get-Command ssh.exe -ErrorAction Stop).Source

	$sshArgs = @(
		"-i", $tempKeyPath,
		"-p", $TargetPort,
		"-o", "IdentityAgent=none",
		"-o", "ExitOnForwardFailure=yes",
		"-L", "$localForwardPort`:127.0.0.1:$RDPPort",
		"-o", "StrictHostKeyChecking=accept-new",
		"-N",
		"$Target"
	)

	Write-Host "SSH alagut inditasa: $Target on local port $localForwardPort"
	$sshProcess = Start-Process -FilePath $sshExecutable -ArgumentList $sshArgs -PassThru -WindowStyle Hidden
	Wait-ForLocalPort -Port $localForwardPort

	Write-Host "RDP kapcsolat inditasa"
	$mstscExecutable = (Get-Command mstsc.exe -ErrorAction Stop).Source
	$mstscArgs = @(
		"/v:localhost:$localForwardPort"
	)
	& $mstscExecutable @mstscArgs
}
catch {
	if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
		$statusCode = [int]$_.Exception.Response.StatusCode
		if ($statusCode -eq 401) {
			Write-Error "Hibas jelszo vagy 2FA kod (401 Unauthorized)."
		}
		else {
			Write-Error ("Sikertelen kulcs letoltes. HTTP status: {0}" -f $statusCode)
		}
	}
	else {
		Write-Error $_
	}

	exit 1
}
finally {
	if ($sshProcess -and -not $sshProcess.HasExited) {
		Stop-Process -Id $sshProcess.Id -Force -ErrorAction SilentlyContinue
	}

	Cleanup-KeyFile -Path $tempKeyPath
}

