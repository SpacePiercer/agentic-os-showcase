# toast.ps1 "Title" "Body" — native Windows toast, no modules needed (PS 5.1 WinRT).
param(
    [Parameter(Mandatory = $true)][string]$Title,
    [string]$Body = ""
)

[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

$xml = @"
<toast scenario="reminder">
  <visual><binding template="ToastGeneric">
    <text>$([System.Security.SecurityElement]::Escape($Title))</text>
    <text>$([System.Security.SecurityElement]::Escape($Body))</text>
  </binding></visual>
</toast>
"@

$doc = New-Object Windows.Data.Xml.Dom.XmlDocument
$doc.LoadXml($xml)
# ponytail: borrow PowerShell's own AppId so no Start-menu app registration is needed
$appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show(
    (New-Object Windows.UI.Notifications.ToastNotification($doc)))
