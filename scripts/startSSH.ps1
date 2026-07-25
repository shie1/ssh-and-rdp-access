param(
	[string]$BaseUrl = "!<<ENV_BASE_URL>>",
	[string]$Target = "!<<ENV_TARGET>>",
	[int]$TargetPort = "!<<ENV_TARGET_PORT>>",
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
		Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
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

$privateKey = $null
$tempKeyPath = Join-Path -Path $env:TEMP -ChildPath ("ssh-key-{0}.pem" -f ([Guid]::NewGuid().ToString("N")))

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
		"-o", "StrictHostKeyChecking=accept-new",
		"$Target"
	)

	if (-not [string]::IsNullOrWhiteSpace($RemoteCommand)) {
		$sshArgs += $RemoteCommand
	}

	Write-Host "SSH kapcsolat inditasa: $Target"
	& $sshExecutable @sshArgs
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
	Cleanup-KeyFile -Path $tempKeyPath
}

