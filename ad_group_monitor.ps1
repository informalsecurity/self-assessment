function Get-WinEventTail() {
    $StartTime = Get-Date 
    $EndTime = $StartTime.AddSeconds(-310)
    $temp = Get-WmiObject -Namespace root\cimv2 -Class Win32_ComputerSystem | Select Name, Domain
    $ComputerName = $temp.Name
    $Domain = $temp.Domain
    try {
        $clength = Measure-Command {$data = Get-WinEvent -FilterHashtable @{
            LogName='Security'
            ID=4728,4732
            Level=4
            StartTime=$EndTime
            EndTime=$StartTime
        } -ErrorAction SilentlyContinue}
        if ($data) {
            foreach ($event in $data) {
                $message = $event.Message
                $message = $message -Split [Environment]::NewLine
                $member = $false
                foreach ($line in $message) {
                    if ($line -like "*Member:*") {
                        $member = $true
                    }
                    if ($line -like "*Account Name*") {
                        if (!($member)) {
                            $account = ($line -Split ":")[1].Trim()
                        }
                    }
                    if ($line -like "*Account Domain*") {
                        $domain = ($line -Split ":")[1].Trim()
                    }
                    if ($line -like "*Group Name*") {
                        $group = ($line -Split ":")[1].Trim()
                    }
                }
                    
                $config = Get-Content C:\Group_Monitoring\monitor.json | ConvertFrom-Json
                if ($config.groups_to_monitor.Contains($group)) {
                    $txtMessage = "$domain\$account was added to $group on DC $ComputerName on Domain $Domain"
                    $From = $config.from
                    $To = $config.to
                    $Subject = "Alert"
                    $Body = $txtMessage
                    $SMTPServer = "smtp.gmail.com"
                    $SMTPPort = "587"
                    $credentials = New-Object Management.Automation.PSCredential $From, ($config.app_pass | ConvertTo-SecureString -AsPlainText -Force)
                    Send-MailMessage -From $From -to $To -Subject $Subject -Body $Body -SmtpServer $SMTPServer -port $SMTPPort -UseSsl -Credential $credentials
                }
            }
        } else {
            Write-Progress "No Changes Found"
        }
    } catch {
        Write-Progress "Something Went Wrong"
    }
}

Get-WinEventTail
