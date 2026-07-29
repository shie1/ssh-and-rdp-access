param(
	[string]$BaseUrl = "!<<ENV_BASE_URL>>",
	[string]$Target = "!<<ENV_TARGET>>",
	[int]$TargetPort = "!<<ENV_SSH_PORT>>",
	[int]$RDPPort = "!<<ENV_RDP_PORT>>",
	[string]$RDPUsername = "!<<ENV_RDP_USERNAME>>",
	[string]$RDPPassword = "!<<ENV_RDP_PASSWORD>>",
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

function Remove-RdpCredential {
	param([string]$TargetHost)

	if ([string]::IsNullOrWhiteSpace($TargetHost)) {
		return
	}

	try {
		# Remove credentials stored specifically for TERMSRV/TargetHost
		cmdkey.exe /delete:"TERMSRV/$TargetHost" *>$null
	}
	catch {
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
$tempPathGuid = [Guid]::NewGuid().ToString("N")
$tempKeyPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("ssh-key-{0}.pem" -f $tempPathGuid)
$tempRdpPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("rdp-config-{0}.rdp" -f $tempPathGuid)

$localForwardPort = Get-FreeLocalPort
$targetAddress = "127.0.0.1:$localForwardPort"

$sshProcess = $null
$mstscProcess = $null

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

	Write-Host "SSH alagut inditasa: $Target on local port $localForwardPort to 127.0.0.1`:$RDPPort"
	$sshProcess = Start-Process -FilePath $sshExecutable -ArgumentList $sshArgs -PassThru -WindowStyle Hidden
	Wait-ForLocalPort -Port $localForwardPort

	# Create Windows Credential for RDP auto-login
	Write-Host "RDP hitelesito adatok mentese a Credential Managerbe..."
	cmdkey.exe /generic:"TERMSRV/$targetAddress" /user:"$RDPUsername" /pass:"$RDPPassword" *>$null

	# Build custom RDP profile with updated target host/port
	$rdpContent = @"
screen mode id:i:2
use multimon:i:0
desktopwidth:i:1920
desktopheight:i:1080
session bpp:i:32
winposstr:s:0,1,362,0,1658,839
compression:i:1
keyboardhook:i:2
audiocapturemode:i:1
videoplaybackmode:i:1
connection type:i:2
networkautodetect:i:0
bandwidthautodetect:i:1
displayconnectionbar:i:1
enableworkspacereconnect:i:0
disable wallpaper:i:1
allow font smoothing:i:0
allow desktop composition:i:0
disable full window drag:i:1
disable menu anims:i:1
disable themes:i:0
disable cursor setting:i:0
bitmapcachepersistenable:i:1
full address:s:$targetAddress
audiomode:i:0
redirectprinters:i:1
redirectlocation:i:0
redirectcomports:i:0
redirectsmartcards:i:1
redirectwebauthn:i:1
redirectclipboard:i:1
redirectposdevices:i:1
autoreconnection enabled:i:1
authentication level:i:2
prompt for credentials:i:0
negotiate security layer:i:1
remoteapplicationmode:i:0
alternate shell:s:
shell working directory:s:
gatewayhostname:s:
gatewayusagemethod:i:4
gatewaycredentialssource:i:4
gatewayprofileusagemethod:i:0
promptcredentialonce:i:0
gatewaybrokeringtype:i:0
use redirection server name:i:1
rdgiskdcproxy:i:0
kdcproxyname:s:
enablerdsaadauth:i:0
username:s:$RDPUsername
"@

	Set-Content -LiteralPath $tempRdpPath -Value $rdpContent -Encoding UTF8

	Write-Host "RDP kapcsolat inditasa profil alapon"
	$mstscExecutable = (Get-Command mstsc.exe -ErrorAction Stop).Source
	$mstscProcess = Start-Process -FilePath $mstscExecutable -ArgumentList @($tempRdpPath) -PassThru
	Wait-Process -Id $mstscProcess.Id
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
	if ($mstscProcess -and -not $mstscProcess.HasExited) {
		Stop-Process -Id $mstscProcess.Id -Force -ErrorAction SilentlyContinue
	}

	if ($sshProcess -and -not $sshProcess.HasExited) {
		Stop-Process -Id $sshProcess.Id -Force -ErrorAction SilentlyContinue
	}

	# Clean up credentials and temp files
	Remove-RdpCredential -TargetHost $targetAddress
	Cleanup-KeyFile -Path $tempKeyPath
	Cleanup-KeyFile -Path $tempRdpPath
}