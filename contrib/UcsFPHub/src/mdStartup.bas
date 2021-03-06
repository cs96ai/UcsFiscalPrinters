Attribute VB_Name = "mdStartup"
'=========================================================================
'
' UcsFPHub (c) 2019-2020 by Unicontsoft
'
' Unicontsoft Fiscal Printers Hub
'
' This project is licensed under the terms of the MIT license
' See the LICENSE file in the project root for more information
'
'=========================================================================
Option Explicit
DefObj A-Z
Private Const MODULE_NAME As String = "mdStartup"

'=========================================================================
' API
'=========================================================================

Private Const HKEY_CLASSES_ROOT         As Long = &H80000000
Private Const SAM_WRITE                 As Long = &H20007
Private Const REG_SZ                    As Long = 1

Private Declare Sub ExitProcess Lib "kernel32" (ByVal uExitCode As Long)
Private Declare Function SetEnvironmentVariable Lib "kernel32" Alias "SetEnvironmentVariableA" (ByVal lpName As String, ByVal lpValue As String) As Long
Private Declare Function RegOpenKeyEx Lib "advapi32" Alias "RegOpenKeyExA" (ByVal hKey As Long, ByVal lpSubKey As String, ByVal ulOptions As Long, ByVal samDesired As Long, phkResult As Long) As Long
Private Declare Function RegCreateKeyEx Lib "advapi32" Alias "RegCreateKeyExA" (ByVal hKey As Long, ByVal lpSubKey As String, ByVal Reserved As Long, ByVal lpClass As Long, ByVal dwOptions As Long, ByVal samDesired As Long, ByVal lpSecurityAttributes As Long, phkResult As Long, lpdwDisposition As Long) As Long
Private Declare Function RegCloseKey Lib "advapi32" (ByVal hKey As Long) As Long
Private Declare Function RegSetValueEx Lib "advapi32" Alias "RegSetValueExA" (ByVal hKey As Long, ByVal lpValueName As String, ByVal Reserved As Long, ByVal dwType As Long, lpData As Any, ByVal cbData As Long) As Long         ' Note that if you declare the lpData parameter as String, you must pass it By Value.
Private Declare Function SHDeleteKey Lib "shlwapi" Alias "SHDeleteKeyA" (ByVal hKey As Long, ByVal szSubKey As String) As Long

'=========================================================================
' Constants and member variables
'=========================================================================

Private Const STR_LATEST_COMMIT         As String = ""
Public Const STR_VERSION                As String = "0.1.35" & STR_LATEST_COMMIT
Public Const STR_SERVICE_NAME           As String = "UcsFPHub"
Public Const DEF_LISTEN_PORT            As Long = 8192
Private Const STR_APPID_GUID            As String = "{6E78E71A-35B2-4D23-A88C-4C2858430329}"
Private Const STR_SVC_INSTALL           As String = "��������� NT ������ %1..."
Private Const STR_SVC_UNINSTALL         As String = "����������� NT ������ %1..."
Private Const STR_SUCCESS               As String = "�����"
Private Const STR_FAILURE               As String = "������: "
Private Const STR_WARN                  As String = "��������������: "
Private Const STR_AUTODETECTING_PRINTERS As String = "����������� ������� �� ��������"
Private Const STR_ENVIRON_VARS_FOUND    As String = "������������� %1 ���������� �� �������"
Private Const STR_ONE_PRINTER_FOUND     As String = "������� 1 �������"
Private Const STR_PRINTERS_FOUND        As String = "�������� %1 ��������"
Private Const STR_PRESS_CTRLC           As String = "��������� Ctrl+C �� �����"
Private Const STR_LOADING_CONFIG        As String = "������� ������������ �� %1"
'--- errors
Private Const ERR_CONFIG_NOT_FOUND      As String = "������: ��������������� ���� %1 �� � �������"
Private Const ERR_PARSING_CONFIG        As String = "������: ��������� %1: %2"
Private Const ERR_ENUM_PORTS            As String = "������: ����������� �� ������� �������: %1"
Private Const ERR_WARN_ACCESS           As String = "��������������: ������� %1: %2"
Private Const ERR_REGISTER_APPID_FAILED As String = "��������� ����������� �� AppID. %1"
'--- formats
Private Const FORMAT_TIME_ONLY          As String = "hh:nn:ss"
Public Const FORMAT_BASE_2              As String = "0.00"
Public Const FORMAT_BASE_3              As String = "0.000"

Private m_oOpt                      As Object
Private m_oPrinters                 As Object
Private m_oConfig                   As Object
Private m_cEndpoints                As Collection
Private m_bIsService                As Boolean
Private m_oLogger                   As Object
Private m_bStarted                  As Boolean

'=========================================================================
' Error handling
'=========================================================================

Private Sub PrintError(sFunction As String)
    #If USE_DEBUG_LOG <> 0 Then
        DebugLog MODULE_NAME, sFunction & "(" & Erl & ")", Err.Description & " &H" & Hex$(Err.Number), vbLogEventTypeError
    #Else
        Debug.Print "Critical error: " & Err.Description & " [" & MODULE_NAME & "." & sFunction & "]"
    #End If
End Sub

'=========================================================================
' Properties
'=========================================================================

Property Get IsRunningAsService() As Boolean
    IsRunningAsService = m_bIsService
End Property

Property Get Logger() As Object
    Const FUNC_NAME     As String = "Logger [get]"
    
    If m_oLogger Is Nothing Then
        With New cFiscalPrinter
            Set m_oLogger = .Logger
        End With
        m_oLogger.Log 0, MODULE_NAME, FUNC_NAME, App.ProductName & " v" & STR_VERSION
    End If
    Set Logger = m_oLogger
End Property

Property Set Logger(oValue As Object)
    With New cFiscalPrinter
        Set .Logger = oValue
    End With
    Set m_oLogger = oValue
End Property

Property Set ProtocolConfig(oValue As Object)
    With New cFiscalPrinter
        Set .ProtocolConfig = oValue
    End With
End Property

'=========================================================================
' Functions
'=========================================================================

Public Sub Main()
    Dim lExitCode       As Long
    
    lExitCode = Process(SplitArgs(Command$), m_bStarted)
    m_bStarted = True
    If Not InIde And lExitCode <> -1 Then
        Call ExitProcess(lExitCode)
    End If
End Sub

Private Function Process(vArgs As Variant, ByVal bNoLogo As Boolean) As Long
    Const FUNC_NAME     As String = "Process"
    Dim sConfFile       As String
    Dim sError          As String
    Dim vKey            As Variant
    Dim lIdx            As Long
    
    On Error GoTo EH
    Set m_oOpt = GetOpt(vArgs, "config:-config:c")
    '--- normalize options: convert -o and -option to proper long form (--option)
    For Each vKey In Split("nologo config:c install:i uninstall:u systray:s hidden help:h:?")
        vKey = Split(vKey, ":")
        For lIdx = 0 To UBound(vKey)
            If IsEmpty(m_oOpt.Item("--" & At(vKey, 0))) And Not IsEmpty(m_oOpt.Item("-" & At(vKey, lIdx))) Then
                m_oOpt.Item("--" & At(vKey, 0)) = m_oOpt.Item("-" & At(vKey, lIdx))
            End If
        Next
    Next
    If Not C_Bool(m_oOpt.Item("--nologo")) And Not bNoLogo Then
        ConsolePrint App.ProductName & " v" & STR_VERSION & " (c) 2019-2020 by Unicontsoft" & vbCrLf & vbCrLf
    End If
    If C_Bool(m_oOpt.Item("--help")) Then
        ConsolePrint "Usage: " & App.EXEName & ".exe [options...]" & vbCrLf & vbCrLf & _
                    "Options:" & vbCrLf & _
                    "  -c, --config FILE   read configuration from FILE" & vbCrLf & _
                    "  -i, --install       install NT service (with config file from -c option)" & vbCrLf & _
                    "  -u, --uninstall     remove NT service" & vbCrLf & _
                    "  -s, --systray       show icon in systray" & vbCrLf
        GoTo QH
    End If
    '--- setup config filename
    sConfFile = C_Str(m_oOpt.Item("--config"))
    If LenB(sConfFile) = 0 Then
        sConfFile = PathCombine(App.Path, App.EXEName & ".conf")
        If Not FileExists(sConfFile) Then
            sConfFile = PathCombine(GetSpecialFolder(ucsOdtLocalAppData) & "\Unicontsoft\UcsFPHub", App.EXEName & ".conf")
            If Not FileExists(sConfFile) Then
                sConfFile = vbNullString
            End If
        End If
    End If
    '--- setup service
    If NtServiceInit(STR_SERVICE_NAME) Then
        m_bIsService = True
        '--- cannot handle these as NT service
        m_oOpt.Item("--systray") = Empty
        m_oOpt.Item("--install") = Empty
        m_oOpt.Item("--uninstall") = Empty
    End If
    If C_Bool(m_oOpt.Item("--install")) Then
        ConsolePrint Printf(STR_SVC_INSTALL, STR_SERVICE_NAME) & vbCrLf
        If LenB(sConfFile) <> 0 Then
            sConfFile = " --config " & ArgvQuote(sConfFile)
        End If
        If Not pvRegisterServiceAppID(STR_SERVICE_NAME, App.ProductName & " (" & STR_VERSION & ")", App.EXEName & ".exe", STR_APPID_GUID, Error:=sError) Then
            ConsoleError STR_WARN & sError & vbCrLf
        End If
        If Not NtServiceInstall(STR_SERVICE_NAME, App.ProductName & " (" & STR_VERSION & ")", GetProcessName() & sConfFile, Error:=sError) Then
            ConsoleError STR_FAILURE
            ConsoleColorError FOREGROUND_RED, FOREGROUND_MASK, sError & vbCrLf
        Else
            ConsolePrint STR_SUCCESS & vbCrLf
        End If
        GoTo QH
    ElseIf C_Bool(m_oOpt.Item("--uninstall")) Then
        ConsolePrint Printf(STR_SVC_UNINSTALL, STR_SERVICE_NAME) & vbCrLf
        If Not pvUnregisterServiceAppID(App.EXEName & ".exe", STR_APPID_GUID, Error:=sError) Then
            ConsoleError STR_WARN & sError & vbCrLf
        End If
        If Not NtServiceUninstall(STR_SERVICE_NAME, Error:=sError) Then
            ConsoleError STR_FAILURE
            ConsoleColorError FOREGROUND_RED, FOREGROUND_MASK, sError
        Else
            ConsolePrint STR_SUCCESS & vbCrLf
        End If
        GoTo QH
    End If
    '--- read config file
    If LenB(sConfFile) <> 0 Then
        If Not FileExists(sConfFile) Then
            DebugLog MODULE_NAME, FUNC_NAME, Printf(ERR_CONFIG_NOT_FOUND, sConfFile), vbLogEventTypeError
            Process = 1
            GoTo QH
        End If
        If Not JsonParse(ReadTextFile(sConfFile), m_oConfig, Error:=sError) Then
            DebugLog MODULE_NAME, FUNC_NAME, Printf(ERR_PARSING_CONFIG, sConfFile, sError), vbLogEventTypeError
            Process = 1
            GoTo QH
        End If
        DebugLog MODULE_NAME, FUNC_NAME, Printf(STR_LOADING_CONFIG, sConfFile)
        JsonExpandEnviron m_oConfig
    Else
        JsonItem(m_oConfig, "Printers/Autodetect") = True
        JsonItem(m_oConfig, "Endpoints/0/Binding") = "RestHttp"
        JsonItem(m_oConfig, "Endpoints/0/Address") = "127.0.0.1:" & DEF_LISTEN_PORT
    End If
    '--- respawn hidden in systray
    If C_Bool(m_oOpt.Item("--systray")) Then
        If Not C_Bool(m_oOpt.Item("--hidden")) And Not InIde Then
            frmIcon.Restart AddParam:="--hidden"
            GoTo QH
        ElseIf Not frmIcon.Init(m_oOpt, sConfFile, App.ProductName & " v" & STR_VERSION) Then
            Process = 1
            GoTo QH
        End If
        Process = -1
    End If
    '--- setup environment and procotol configuration
    lIdx = JsonItem(m_oConfig, -1)
    If lIdx > 0 Then
        DebugLog MODULE_NAME, FUNC_NAME, Printf(STR_ENVIRON_VARS_FOUND, lIdx)
        For Each vKey In JsonKeys(m_oConfig, "Environment")
            Call SetEnvironmentVariable(vKey, C_Str(JsonItem(m_oConfig, "Environment/" & vKey)))
        Next
        FlushDebugLog
    End If
    Set ProtocolConfig = C_Obj(JsonItem(m_oConfig, "ProtocolConfig"))
    '--- first register local endpoints
    Set m_oPrinters = Nothing
    JsonItem(m_oPrinters, vbNullString) = Empty
    If Not pvCreateEndpoints(m_oPrinters, "local", m_cEndpoints) Then
        GoTo QH
    End If
    '--- leave longer to complete auto-detection for last step
    If Not pvCollectPrinters(m_oPrinters) Then
        GoTo QH
    End If
    DebugLog MODULE_NAME, FUNC_NAME, Printf(IIf(JsonItem(m_oPrinters, "Count") = 1, STR_ONE_PRINTER_FOUND, STR_PRINTERS_FOUND), _
        JsonItem(m_oPrinters, "Count"))
    '--- then register http/mssql endpoints
    If Not pvCreateEndpoints(m_oPrinters, "resthttp mssqlservicebroker mysqlmessagequeue", m_cEndpoints) Then
        GoTo QH
    End If
    If m_bIsService Then
        Do While Not NtServiceQueryStop()
            '--- do nothing
        Loop
        TerminateEndpoints
        NtServiceTerminate
        FlushDebugLog
    ElseIf Not C_Bool(m_oOpt.Item("--systray")) Then
        ConsolePrint STR_PRESS_CTRLC & vbCrLf
        Do
            ConsoleRead
            DoEvents
            FlushDebugLog
        Loop
    End If
QH:
    Exit Function
EH:
    PrintError FUNC_NAME
    Process = 100
End Function

Private Function pvCollectPrinters(oRetVal As Object) As Boolean
    Const FUNC_NAME     As String = "pvCollectPrinters"
    Dim oFP             As cFiscalPrinter
    Dim sResponse       As String
    Dim oJson           As Object
    Dim vKey            As Variant
    Dim oRequest        As Object
    Dim sDeviceString   As String
    Dim sKey            As String
    Dim oAliases        As Object
    Dim oInfo           As Object
    
    On Error GoTo EH
    Set oFP = New cFiscalPrinter
    JsonItem(oRetVal, "Ok") = True
    JsonItem(oRetVal, "Count") = 0
    If JsonItem(m_oConfig, "Printers/Autodetect") Then
        DebugLog MODULE_NAME, FUNC_NAME, STR_AUTODETECTING_PRINTERS
        If oFP.EnumPorts(sResponse) And JsonParse(sResponse, oJson) Then
            If Not JsonItem(oJson, "Ok") Then
                DebugLog MODULE_NAME, FUNC_NAME, Printf(ERR_ENUM_PORTS, vKey, JsonItem(oJson, "ErrorText")), vbLogEventTypeError
            Else
                For Each vKey In JsonKeys(oJson, "SerialPorts")
                    If LenB(JsonItem(oJson, "SerialPorts/" & vKey & "/Protocol")) <> 0 Then
                        sDeviceString = "Protocol=" & JsonItem(oJson, "SerialPorts/" & vKey & "/Protocol") & _
                            ";Port=" & JsonItem(oJson, "SerialPorts/" & vKey & "/Port") & _
                            ";Speed=" & JsonItem(oJson, "SerialPorts/" & vKey & "/Speed")
                        Set oRequest = Nothing
                        JsonItem(oRequest, "DeviceString") = sDeviceString
                        JsonItem(oRequest, "IncludeTaxNo") = True
                        If oFP.GetDeviceInfo(JsonDump(oRequest, Minimize:=True), sResponse) And JsonParse(sResponse, oInfo) Then
                            sKey = JsonItem(oInfo, "DeviceSerialNo")
                            If LenB(sKey) <> 0 Then
                                JsonItem(oInfo, "Ok") = Empty
                                JsonItem(oInfo, "DeviceString") = sDeviceString
                                JsonItem(oInfo, "DeviceHost") = GetErrorComputerName()
                                JsonItem(oInfo, "DevicePort") = pvGetDevicePort(sDeviceString)
                                JsonItem(oInfo, "Autodetected") = True
                                JsonItem(oRetVal, sKey) = oInfo
                                JsonItem(oRetVal, "Count") = JsonItem(oRetVal, "Count") + 1
                            End If
                        End If
                    End If
                Next
            End If
        End If
    End If
    For Each vKey In JsonKeys(m_oConfig, "Printers")
        sDeviceString = C_Str(JsonItem(m_oConfig, "Printers/" & vKey & "/DeviceString"))
        If LenB(sDeviceString) <> 0 Then
            Set oRequest = Nothing
            JsonItem(oRequest, "DeviceString") = sDeviceString
            JsonItem(oRequest, "IncludeTaxNo") = True
            If oFP.GetDeviceInfo(JsonDump(oRequest, Minimize:=True), sResponse) And JsonParse(sResponse, oInfo) Then
                If Not JsonItem(oInfo, "Ok") Then
                    DebugLog MODULE_NAME, FUNC_NAME, Printf(ERR_WARN_ACCESS, vKey, JsonItem(oInfo, "ErrorText")), vbLogEventTypeWarning
                Else
                    sKey = Zn(JsonItem(oInfo, "DeviceSerialNo"), vKey)
                    If LenB(sKey) <> 0 Then
                        JsonItem(oInfo, "Ok") = Empty
                        JsonItem(oInfo, "DeviceString") = sDeviceString
                        JsonItem(oInfo, "DeviceHost") = GetErrorComputerName()
                        JsonItem(oInfo, "DevicePort") = pvGetDevicePort(sDeviceString)
                        JsonItem(oInfo, "Description") = JsonItem(m_oConfig, "Printers/" & vKey & "/Description")
                        If IsEmpty(JsonItem(oRetVal, sKey)) Then
                            JsonItem(oRetVal, "Count") = JsonItem(oRetVal, "Count") + 1
                        End If
                        JsonItem(oRetVal, sKey) = oInfo
                        If IsEmpty(JsonItem(oAliases, vKey)) Then
                            JsonItem(oAliases, "Count") = JsonItem(oAliases, "Count") + 1
                        End If
                        JsonItem(oAliases, vKey & "/DeviceSerialNo") = sKey
                    End If
                End If
            End If
        End If
    Next
    If Not oAliases Is Nothing Then
        JsonItem(oRetVal, "Aliases") = oAliases
    End If
    '--- success
    pvCollectPrinters = True
    Exit Function
EH:
    PrintError FUNC_NAME
    Resume Next
End Function

Private Function pvCreateEndpoints(oPrinters As Object, sBindings As String, cRetVal As Collection) As Boolean
    Const FUNC_NAME     As String = "pvCreateEndpoints"
    Dim vKey            As Variant
    Dim oRestEndpoint   As cRestEndpoint
    Dim oQueueEndpoint  As cQueueEndpoint
    Dim oLocalEndpoint  As frmLocalEndpoint
    
    On Error GoTo EH
    Set cRetVal = New Collection
    '--- first local endpoint (faster registration)
    For Each vKey In JsonKeys(m_oConfig, "Endpoints")
        If InStr(sBindings, LCase$(JsonItem(m_oConfig, "Endpoints/" & vKey & "/Binding"))) > 0 Then
            Select Case LCase$(JsonItem(m_oConfig, "Endpoints/" & vKey & "/Binding"))
            Case "local"
                Set oLocalEndpoint = New frmLocalEndpoint
                If oLocalEndpoint.frInit(JsonItem(m_oConfig, "Endpoints/" & vKey), oPrinters) Then
                    cRetVal.Add oLocalEndpoint
                End If
            Case "resthttp"
                Set oRestEndpoint = New cRestEndpoint
                If oRestEndpoint.Init(JsonItem(m_oConfig, "Endpoints/" & vKey), oPrinters) Then
                    cRetVal.Add oRestEndpoint
                End If
            Case "mssqlservicebroker", "mysqlmessagequeue"
                Set oQueueEndpoint = New cQueueEndpoint
                If oQueueEndpoint.Init(JsonItem(m_oConfig, "Endpoints/" & vKey), oPrinters) Then
                    cRetVal.Add oQueueEndpoint
                End If
            End Select
        End If
    Next
    '--- always init local endpoint
    If oLocalEndpoint Is Nothing And InStr(sBindings, "local") > 0 Then
        Set oLocalEndpoint = New frmLocalEndpoint
        If oLocalEndpoint.frInit(Nothing, oPrinters) Then
            cRetVal.Add oLocalEndpoint
        End If
    End If
    '--- success
    pvCreateEndpoints = True
    Exit Function
EH:
    PrintError FUNC_NAME
    Resume Next
End Function

Public Sub DebugLog(sModule As String, sFunction As String, sText As String, Optional ByVal eType As LogEventTypeConstants = vbLogEventTypeInformation)
    Dim sPrefix         As String
    Dim sSuffix         As String
    
    Logger.Log eType, sModule, sFunction, sText
    sPrefix = Format$(Now, FORMAT_TIME_ONLY) & Right$(Format$(Timer, FORMAT_BASE_3), 4) & ": "
'    sSuffix = " [" & sModule & "." & sFunction & "]"
    If Logger.LogFile = -1 And m_bIsService Then
        App.LogEvent sText & sSuffix, eType
    ElseIf eType = vbLogEventTypeError Then
        ConsoleColorError FOREGROUND_RED, FOREGROUND_MASK, sPrefix & sText & sSuffix & vbCrLf
    Else
        ConsolePrint sPrefix & sText & sSuffix & vbCrLf
    End If
End Sub

Public Sub DebugDataDump(sModule As String, sFunction As String, sPrefix As String, sText As String)
    Logger.DataDump sModule, sFunction, sPrefix, sText
End Sub

Public Sub FlushDebugLog()
    Set Logger = Nothing
End Sub

Public Sub TerminateEndpoints()
    Dim oElem           As IEndpoint
    
    If Not m_cEndpoints Is Nothing Then
        For Each oElem In m_cEndpoints
            oElem.Terminate
        Next
        Set m_cEndpoints = Nothing
    End If
End Sub

Private Function pvRegisterServiceAppID(sServiceName As String, sDisplayName As String, sExeFile As String, sGuid As String, Optional Error As String) As Boolean
    If Not pvRegSetStringValue(HKEY_CLASSES_ROOT, "AppID\" & sExeFile, "AppID", sGuid) Then
        GoTo QH
    End If
    If Not pvRegSetStringValue(HKEY_CLASSES_ROOT, "AppID\" & sGuid, vbNullString, sDisplayName) Then
        GoTo QH
    End If
    If Not pvRegSetStringValue(HKEY_CLASSES_ROOT, "AppID\" & sGuid, "LocalService", sServiceName) Then
        GoTo QH
    End If
    '--- success
    pvRegisterServiceAppID = True
QH:
    If Not pvRegisterServiceAppID Then
        Error = Printf(ERR_REGISTER_APPID_FAILED, GetErrorDescription(Err.LastDllError))
    End If
End Function

Private Function pvRegSetStringValue(ByVal hRoot As Long, sSubKey As String, sName As String, sValue As String) As Boolean
    Dim hKey            As Long
    Dim dwDummy         As Long
    
    If RegCreateKeyEx(hRoot, sSubKey, 0, 0, 0, SAM_WRITE, 0, hKey, dwDummy) = 0 Then
        Call RegCloseKey(hKey)
    End If
    If RegOpenKeyEx(hRoot, sSubKey, 0, SAM_WRITE, hKey) <> 0 Then
        GoTo QH
    End If
    If RegSetValueEx(hKey, sName, 0, REG_SZ, ByVal sValue, Len(sValue)) <> 0 Then
        GoTo QH
    End If
    '--- success
    pvRegSetStringValue = True
QH:
    If hKey <> 0 Then
        Call RegCloseKey(hKey)
    End If
End Function

Private Function pvUnregisterServiceAppID(sExeFile As String, sGuid As String, Optional Error As String) As Boolean
    SHDeleteKey HKEY_CLASSES_ROOT, "AppID\" & sExeFile
    SHDeleteKey HKEY_CLASSES_ROOT, "AppID\" & sGuid
    Error = vbNullString
    '--- success
    pvUnregisterServiceAppID = True
End Function

Private Function pvGetDevicePort(sDeviceString As String) As String
    Dim oJson           As Object
    Dim sRetVal         As String
    
    Set oJson = ParseDeviceString(sDeviceString)
    If Not IsEmpty(JsonItem(oJson, "Url")) Then
        sRetVal = JsonItem(oJson, "Url")
    ElseIf Not IsEmpty(JsonItem(oJson, "IP")) Then
        sRetVal = JsonItem(oJson, "Port")
        sRetVal = JsonItem(oJson, "IP") & IIf(LenB(sRetVal) <> 0, ":" & sRetVal, vbNullString)
    Else
        sRetVal = JsonItem(oJson, "Speed")
        If sRetVal = "115200" Then
            sRetVal = vbNullString
        End If
        sRetVal = JsonItem(oJson, "Port") & IIf(LenB(sRetVal) <> 0, "," & sRetVal, vbNullString)
    End If
    pvGetDevicePort = sRetVal
End Function
