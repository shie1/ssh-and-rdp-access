param(
	[string]$BaseUrl = "<<ENV_BASE_URL>>",
	[string]$Target = "<<ENV_TARGET>>",
	[int]$TargetPort = "<<ENV_TARGET_PORT>>",
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

$tempKeyPath = Join-Path -Path $env:TEMP -ChildPath ("ssh-key-{0}.tmp" -f ([Guid]::NewGuid().ToString("N")))

try {
	Write-Host "SSH kulcs letoltese..."

	Invoke-WebRequest `
		-Uri $keyEndpoint `
		-Method Get `
		-Headers @{ Authorization = $authHeader } `
		-OutFile $tempKeyPath | Out-Null

	# Restrict access to the current user for better key file hygiene.
	$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
	icacls $tempKeyPath /inheritance:r /grant:r "$currentIdentity:R" | Out-Null

	$sshArgs = @(
		"-i", $tempKeyPath,
		"-p", $TargetPort,
		"-o", "IdentitiesOnly=yes",
		"-o", "StrictHostKeyChecking=accept-new",
		"$Target"
	)

	if (-not [string]::IsNullOrWhiteSpace($RemoteCommand)) {
		$sshArgs += $RemoteCommand
	}

	Write-Host "SSH kapcsolat inditasa: $Target"
	& ssh @sshArgs
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

