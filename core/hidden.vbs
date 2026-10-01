' hidden.vbs - run a command with no console window.
' Task Scheduler + powershell.exe always flashes a console, even with
' -WindowStyle Hidden. wscript.exe has no console at all, so wrapping the
' real command here makes AgenticOS jobs invisible while still running in the
' interactive session (so toast notifications still appear).
'
' Usage (as a Task Scheduler action):
'   Program:   wscript.exe
'   Arguments: "C:\path\to\agentic-os\core\hidden.vbs" powershell.exe -NoProfile -File "...\run-job.ps1" -Name x -Skill "/x"

Dim sh, i, a, cmd
Set sh = CreateObject("WScript.Shell")
cmd = ""
For i = 0 To WScript.Arguments.Count - 1
  a = WScript.Arguments(i)
  If InStr(a, " ") > 0 Then a = """" & a & """"
  cmd = cmd & a & " "
Next
' 0 = hidden window, True = wait, so Task Scheduler still sees the exit code
WScript.Quit sh.Run(cmd, 0, True)
