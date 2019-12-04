#EGRESS WEB PROXY TESTER
Write-Host "## WEB FILTER STRENGTH CONFIGURATION TESTER -- Assessment Kicked Off"
Write-Host "## WEB FILTER STRENGTH CONFIGURATION TESTER -- Setting up output"
#SETUP OUTPUT

#WEB PROXY TESTING
#Ignore SSL Certificate Issues
Write-Host "## WEB FILTER STRENGTH CONFIGURATION TESTER -- Setting up Environment to Ignore SSL Issues"
add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@

[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
[Net.ServicePointManager]::SecurityProtocol = "tls12,tls11,tls"
Write-Host "## WEB FILTER STRENGTH CONFIGURATION TESTER -- Generating Referrel Headers (tricks the tricky websites)"
#Create Referrel Headers (required for some sites)
$h1 = @{
Accept= 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
'Accept-Language'= 'en-US,en;q=0.5'
'Accept-Encoding'= 'gzip, deflate'
DNT= 1
Referer = 'https://client.google.com'
}

Write-Host "## WEB FILTER STRENGTH CONFIGURATION TESTER -- Creating Variables"
#Setup Dictionary
$ip_dict = @{}
$http_dict = @{}
$https_dict = @{}
$analysis_dict = @{}
$blocked_sites = @()
$aResults = @()

Write-Host "## WEB FILTER STRENGTH CONFIGURATION TESTER -- Importing File Containing Websites/Categories to be tested"
#Import Websites CSV
if (Test-Path variable:global:csv) {
	Write-Host "CSV Exists - Skipping"
    } else {
	$config_path = Read-Host -Prompt " Provide a full path to the FOLDER with the web_sites.csv file (under config directory)"

	do {
    	$tempstuff = test-path $config_path"\websites.csv"
		if ($tempstuff) {
			$csv = Import-csv $config_path"\websites.csv"
		} else {
			$config_path =  Read-Host -Prompt "    Provide a full path to the FOLDER with the web_sites.csv file (under config directory)"
		}
	}until($tempstuff)
}

if (Test-Path variable:global:foutput) {
	Write-Host "GOT IT"
} else {
	$foutput = Read-Host -Prompt "Provide a fulle path to the DIRECTORY for the output of the tool"
}

Write-Host "## WEB FILTER STRENGTH CONFIGURATION TESTER -- Testing Websites Individually"
foreach($item in $csv) {
    
    #RESET VARIABLES
    $httptemp = ""
    $httptitle = ""
    $httpstemp = ""
    $httpstitle = ""
    $http_site_title_hash = ""
    $https_site_title_hash = ""
    $site_ip_hash = ""
    #GET WEBSITE TO TEST
    $website = $item.site
    Write-Host "## WEB FILTER STRENGTH CONFIGURATION TESTER -- CHECKING - $website"
    $category = $item.category
    #GET DNS RESOLUTION & HASH - Allows us to check for OPen DNS or Cisco Umbrella Blockages
    $ip = ([System.Net.Dns]::GetHostAddresses($website)).IPAddressToString
    if ($ip -is [system.array]) {
        $ip = $ip[0]
    }
    try {
        $httptemp = invoke-webrequest -UserAgent "Web Filter Strength Test - Not Malware" -ErrorAction Ignore -UseBasicParsing -TimeoutSec 3 -Headers $h1  http://$website
        $httpcontent = $httptemp.Content -join [Environment]::NewLine
        $httparr = $httpcontent -Split "<title>"
        $temparr = $httparr[1] -Split "</title>"
        $httptitle = $temparr[0]
        $headers = $httptemp.Headers | ConvertTo-Json
    
    }
    catch {
        $httptitle = [int]$_.Exception.Response.StatusCode
        $headers = "NA"

    }
    try {
        $httpstemp = invoke-webrequest  -UserAgent "Web Filter Strength Test - Not Malware" -UseBasicParsing -ErrorAction Ignore -TimeoutSec 3 -Headers $h1  https://$website
        $httpscontent = $httpstemp.Content -join [Environment]::NewLine
        $httpsarr = $httpscontent -Split "<title>"
        $temparr = $httpsarr[1] -Split "</title>"
        $httpstitle = $temparr[0]
    }
    catch {
        $httpstitle = [int]$_.Exception.Response.StatusCode
    }
    #GENERATE HASHES FOR IP AND SITE TITLES
    $StringBuilder = New-Object System.Text.StringBuilder
    [System.Security.Cryptography.HashAlgorithm]::Create("SHA256").ComputeHash([System.Text.Encoding]::UTF8.GetBytes($httptitle))|%{[Void]$StringBuilder.Append($_.ToString("x2"))} 
    $http_site_title_hash = $StringBuilder.ToString()
    $StringBuilder = New-Object System.Text.StringBuilder
    [System.Security.Cryptography.HashAlgorithm]::Create("SHA256").ComputeHash([System.Text.Encoding]::UTF8.GetBytes($httpstitle))|%{[Void]$StringBuilder.Append($_.ToString("x2"))} 
    $https_site_title_hash = $StringBuilder.ToString()
    $StringBuilder = New-Object System.Text.StringBuilder
    [System.Security.Cryptography.HashAlgorithm]::Create("SHA256").ComputeHash([System.Text.Encoding]::UTF8.GetBytes($ip))|%{[Void]$StringBuilder.Append($_.ToString("x2"))} 
    $site_ip_hash = $StringBuilder.ToString()
    #RAW_DETAILS OUTPUT

    if (($httptitle -ne 403) -and ($httptitle -ne 0)) {
        $httpbody = $httptemp.Content.SubString(0,1000)
    } else {
        $httpbody = "NA"
    }
    if (($httpstitle -ne 403) -and ($httptitle -ne 0)) {
        $httpsbody = $httpstemp.Content.SubString(0,1000)
    } else {
        $httpsbody = "NA"
    }
    $output = @{ 
        Site = $website
        StatusCode = $httptemp.StatusCode
	    IP = $ip
	    IPHash = $site_ip_hash
        Headers = $headers
        HTTPTitle = $httptitle
        HTTPBody = $httpbody
        HTTPHash = $http_site_title_hash
        HTTPSTitle = $httpstitle
        HTTPSBody = $httpsbody
        HTTPSHash = $https_site_title_hash
    }
    [pscustomobject]$output | Export-CSV $foutput"\WEB_PROXY_RAW_DATA.csv" -Append -NoTypeInformation

    #UPDATE HASHTABLES
    $ip_dict.Add($website,$site_ip_hash)
    $http_dict.Add($website,$http_site_title_hash)
    $https_dict.Add($website,$https_site_title_hash)
    $hItemDetails = [PSCustomObject]@{    
        WEBSITE = $website
        CATEGORY = $category
        DNS = "ALLOWED"
        HTTP = "ALLOWED"
        HTTPS = "ALLOWED"
    }
    $aResults += $hItemDetails
    $httptemp = ""
    $httpstemp = ""
}
Write-Host "## WEB FILTER STRENGTH CONFIGURATION TESTER -- Performing Post Analysis to Detemrine Blocking"
#POST DATA GATHERING ANALYSIS
#GET THE COUNTS OF HASHES PER ANALYSIS TYPE
$ip_dict_sum = $ip_dict.Values | group  |select-object -Property Name, Count
$most_ip = $ip_dict.Values | group  |select-object -Property Name, Count | Sort-Object Count -Descending | select-Object -First 1
$http_dict_sum = $http_dict.Values | group  |select-object -Property Name, Count
$most_http = $http_dict.Values | group  |select-object -Property Name, Count | Sort-Object Count -Descending | select-Object -First 2
$https_dict_sum = $https_dict.Values | group  |select-object -Property Name, Count
$most_https = $https_dict.Values | group  |select-object -Property Name, Count | Sort-Object Count -Descending | select-Object -First 2
#FIGURE OUT WHICH OCCURRED THE MOST TO DETERMIN BLOCKED METHOD (IF ANY)
$dns = "No"
$inline = "No"
$inline_nt = "No"
if ($most_ip.Count -gt 1) {
    $dns = "Yes"
    $blocked_sites = Foreach ($Key in ($ip_dict.GetEnumerator() | Where-Object {$_.Value -eq $most_ip.Name})){$Key.name}
    Foreach ($Key in ($ip_dict.GetEnumerator() | Where-Object {$_.Value -eq $most_ip.Name})){
        $temp = $aResults | where {$_.WEBSITE -eq $Key.name}
        $temp.DNS="BLOCKED"
        $temp.HTTP="BLOCKED"
        $temp.HTTPS="BLOCKED"
        
    }
    Write-Host "## WEB FILTER STRENGTH CONFIGURATION TESTER -- BLOCKING DNS BASED" -ForegroundColor Yellow
}
if ($most_https[0].Count -gt 2) {
    Foreach ($Key in ($https_dict.GetEnumerator() | Where-Object {$_.Value -eq $most_https[0].Name})){
        $temp = $aResults | where {$_.WEBSITE -eq $Key.name}
        if ($temp.DNS -eq "ALLOWED") {
            $temp.HTTPS="BLOCKED"
            $blocked_sites = $blocked_sites + $Key.name
            $inline = "Yes"
            #Write-Host "## WEB FILTER STRENGTH CONFIGURATION TESTER -- BLOCKING with INLINE HTTPS INTERRUPTION" -ForegroundColor Yellow
        }
    }
    
}
if($most_http[0].Count -gt 2) {
    Foreach ($Key in ($http_dict.GetEnumerator() | Where-Object {$_.Value -eq $most_http[0].Name})){
        $temp = $aResults | where {$_.WEBSITE -eq $Key.name}
        if ($temp.DNS -eq "ALLOWED") {
            $temp.HTTP="BLOCKED"
            $inline = "Yes"
            #Write-Host "## WEB FILTER STRENGTH CONFIGURATION TESTER -- BLOCKING with INLINE HTTP INTERRUPTION" -ForegroundColor Yellow
            $blocked_sites = $blocked_sites + $Key.name
        }
    }
    
}
if ($most_https[1].Count -gt 2) {
    Foreach ($Key in ($https_dict.GetEnumerator() | Where-Object {$_.Value -eq $most_https[1].Name})){
        $temp = $aResults | where {$_.WEBSITE -eq $Key.name}
        if (($temp.DNS -eq "ALLOWED") -and ($temp.HTTPS -eq "ALLOWED")) {
            $temp.HTTPS="BLOCKED"
            $inline_nt = "Yes"
            #Write-Host "## WEB FILTER STRENGTH CONFIGURATION TESTER -- BLOCKING with INLINE HTTP INTERRUPTION (NON-TRADITIONAL INTERRUPT DETECTED)" -ForegroundColor White
            $blocked_sites = $blocked_sites + $Key.name
        }
    }
    
}
if (($most_http[1].Count -gt 2) -and (($most_http[1].Name -eq "d26eae87829adde551bf4b852f9da6b8c3c2db9b65b8b68870632a2db5f53e00") -or ($most_http[1].Name -eq "5feceb66ffc86f38d952786c6d696c79c2dbc239dd4e91b46729d73a27fb57e9"))) {
    Foreach ($Key in ($http_dict.GetEnumerator() | Where-Object {$_.Value -eq $most_http[1].Name})){
        $temp = $aResults | where {$_.WEBSITE -eq $Key.name}
        if (($temp.DNS -eq "ALLOWED") -and ($temp.HTTP -eq "ALLOWED")) {
            $temp.HTTP="BLOCKED"
            $inline_nt = "Yes"
            $blocked_sites = $blocked_sites + $Key.name
            #Write-Host "## WEB FILTER STRENGTH CONFIGURATION TESTER -- BLOCKING with INLINE HTTP INTERRUPTION (NON-TRADITIONAL INTERRUPT DETECTED)" -ForegroundColor White
        }
    }
    
} 
if (($most_https.Count -eq 1) -and ($most_http.Count -eq 1) -and ($most_ip.Count -eq 1)) {
    Write-Host "## WEB FILTER STRENGTH CONFIGURATION TESTER -- NO BLOCKING FOUND" -ForegroundColor Yellow
    $blocked_sites = ""
}

if (($dns -eq "Yes") -and ($inline -eq "Yes" )) {
    Write-Host "BLOCK METHOD APPEARS TO BE A COMBINATION OF DNS-BASED AND INLINE INTERRUPTION"
    if ($inline_nt -eq "Yes") {
        Write-Host "BLOCK METHOD APPEARS TO BE A COMBINATION OF DNS-BASED AND INLINE INTERRUPTION (and 403 NT interrupts)"
    }
} elseif (($dns -eq "Yes") -and ($inline -eq "No" )) {
    Write-Host "BLOCKING METHOD IS DNS BASED"
} elseif (($dns -eq "No") -and ($inline -eq "Yes" )) {
    Write-Host "BLOCKING METHOD IS INLINE REDIRECTION TO BLOCK PAGE"
    if ($inline_nt -eq "Yes") {
        Write-Host "BLOCKING METHOD IS INLINE REDIRECTION TO BLOCK PAGE (and 403 NT interrupts)"
    }
} else {
    $excelsumm.Cells.Item(1,1) = "THERE IS NO BLOCKING"
    if ($inline_nt -eq "Yes") {
        Write-Host "BLOCKING METHOD IS INLINE 403 NT interrupts"
    }
}

$blocked_sites = $blocked_sites -split('`r') | sort | Get-Unique

$final = @()

If ($blocked_sites.length -gt 1) {
    foreach ($item in $csv) {
        if ($blocked_sites -match $item.Site) {
            $temp = $item | select Site, Category, @{n='Blocked';e={"Yes"}}
        } else {
            $temp = $item | select Site, Category, @{n='Blocked';e={"No"}}
        }
        $final += $temp
    }
}

Write-Host "## WEB FILTER STRENGTH CONFIGURATION TESTER -- Generating Output"

ForEach ($item in $aResults) {
    $output = @{ 
        Site = $item.WEBSITE
        Category = $item.CATEGORY
	    DNS = $item.DNS
	    HTTP = $item.HTTP
        HTTPS = $item.HTTPS
    }
    [pscustomobject]$output | Export-CSV $foutput"\WEB_PROXY_WEBSITE_ACCESS_DATA.csv" -Append -NoTypeInformation

}

Write-Host "## WEB FILTER STRENGTH CONFIGURATION TESTER -- SCRIPT HAS COMPLETED RUNNING"
