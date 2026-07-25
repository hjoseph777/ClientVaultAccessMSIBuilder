Option Explicit

Const msiOpenDatabaseModeReadOnly = 0
Const msiOpenDatabaseModeTransact = 1
Dim openMode : openMode = msiOpenDatabaseModeTransact
Dim szConnName
Dim szVaultGUID
Dim szProtocol
Dim szNetworkAddress
Dim szEndpoint
Dim szSPN
Dim szAuthType
Dim szAutoLogin
Dim szTemplatePath
Dim szDatabasePath
Dim szCustomizationXMLFile
Dim bSilent
Dim bSign
Dim oDoc

' Branch for compatibility with the old command line syntax of CustomizeCloudVault.vbs.
Dim szMode : szMode = "old"
If WScript.Arguments.Count >= 1 Then szMode = LCase( WScript.Arguments( 0 ) )
If WScript.Arguments.Count >= 1 And szMode <> "xml" Then

	' Compatibility mode.
	szMode = "old"

	' Check for arguments.
	If WScript.Arguments.Count <> 5 And WScript.Arguments.Count <> 8 Then

		' Show new usage.
		ShowUsage

		' Show old usage.
		WScript.Echo ""
		WScript.Echo "Usage (compatibility mode):"
		WScript.Echo "<MSI file> <Vault GUID> <Protocol> <Network Address> <Endpoint> [ <silent> <sign> <authentication type> ]"
		WScript.Echo ""
		WScript.Echo "Example (compatibility mode):"
		WScript.Echo """M-Files_x86.msi"" {68A79327-5EAF-4E93-ACC2-5E608164F15C} ncacn_http cloudvault351.m-files.com 4466 False True 3"

		' Quit.
		WScript.Quit( 1 )

	End If

	' Get arguments.
	szDatabasePath = WScript.Arguments( 0 )
	szVaultGUID = WScript.Arguments( 1 )
	szProtocol = WScript.Arguments( 2 )
	szNetworkAddress = WScript.Arguments( 3 )
	szEndpoint = WScript.Arguments( 4 )
	bSilent  = False
	If WScript.Arguments.Count > 5 Then bSilent = CBool( WScript.Arguments( 5 ) )
	bSign = True
	If WScript.Arguments.Count > 6 Then bSign  = CBool( WScript.Arguments( 6 ) )
	szAuthType = "3"
	If WScript.Arguments.Count > 7 Then szAuthType  = WScript.Arguments( 7 )
	szConnName = "Cloud Vault"

	' Create an XML file for specifying the needed customization.
	Set oDoc = CreateObject( "MSXML2.DOMDocument.6.0" )
	Dim oNodeRoot : Set oNodeRoot = oDoc.appendChild( oDoc.createElement( "root" ) )

	' Customize product name.
	oNodeRoot.appendChild( oDoc.createElement( "ProductName" ) ).text = "M-Files Cloud Vault"

	' Customize client vault connections.
	Dim oNodeMFClient : Set oNodeMFClient = oNodeRoot.appendChild( oDoc.createElement( "MFClient" ) )
	Dim oNodeVaults : Set oNodeVaults = oNodeMFClient.appendChild( oDoc.createElement( "Vaults" ) )
	Dim oNodeVault : Set oNodeVault = oNodeVaults.appendChild( oDoc.createElement( "Vault" ) )
	oNodeVault.setAttribute "name", szConnName
	oNodeVault.appendChild( oDoc.createElement( "ServerVaultName" ) ).text = szConnName
	oNodeVault.appendChild( oDoc.createElement( "ServerVaultGUID" ) ).text = szVaultGUID
	oNodeVault.appendChild( oDoc.createElement( "ProtocolSequence" ) ).text = szProtocol
	oNodeVault.appendChild( oDoc.createElement( "NetworkAddress" ) ).text = szNetworkAddress
	oNodeVault.appendChild( oDoc.createElement( "Endpoint" ) ).text = szEndpoint
	oNodeVault.appendChild( oDoc.createElement( "AuthType" ) ).text = "#" & szAuthType
	oNodeVault.appendChild( oDoc.createElement( "AutoLogin" ) ).text = "#0"
	oNodeVault.appendChild( oDoc.createElement( "SPN" ) ).text = ""
	oNodeVault.appendChild( oDoc.createElement( "MinimumAuthenticationLevel" ) ).text = "#1"

	' Customize server connections.
	Dim oNodeMFAdmin : Set oNodeMFAdmin = oNodeRoot.appendChild( oDoc.createElement( "MFAdmin" ) )
	Dim oNodeServers : Set oNodeServers = oNodeMFAdmin.appendChild( oDoc.createElement( "Servers" ) )
	Dim oNodeServer : Set oNodeServer = oNodeServers.appendChild( oDoc.createElement( "Server" ) )
	oNodeServer.setAttribute "name", "Cloud Server"
	oNodeServer.appendChild( oDoc.createElement( "ProtocolSequence" ) ).text = szProtocol
	oNodeServer.appendChild( oDoc.createElement( "NetworkAddress" ) ).text = szNetworkAddress
	oNodeServer.appendChild( oDoc.createElement( "Endpoint" ) ).text = szEndpoint
	oNodeServer.appendChild( oDoc.createElement( "AuthType" ) ).text = "#" & szAuthType
	oNodeServer.appendChild( oDoc.createElement( "MinimumAuthenticationLevel" ) ).text = "#1"

	' Save the customization info.
	szCustomizationXMLFile = "VaultInfo.xml"
	oDoc.save szCustomizationXMLFile
	Set oDoc = Nothing

Else

	' Check for arguments.
	If WScript.Arguments.Count <> 6 Then
		ShowUsage
		WScript.Quit( 1 )
	End If

	' Get arguments.
	szMode = LCase( Wscript.Arguments( 0 ) )
	szTemplatePath = Wscript.Arguments( 1 )
	szCustomizationXMLFile = Wscript.Arguments( 2 )
	szDatabasePath = Wscript.Arguments( 3 )
	bSilent = CBool( WScript.Arguments( 4 ) )
	bSign = CBool( WScript.Arguments( 5 ) )

	' Copy from template to the target database.
	Dim oFSO : Set oFSO = CreateObject( "Scripting.FileSystemObject" )
	If Not bSilent Then WScript.Echo ""
	If Not bSilent Then WScript.Echo "Copying """ & szTemplatePath & """ to """ & szDatabasePath & """..."
	oFSO.CopyFile szTemplatePath, szDatabasePath, True

End If

' Connect to the Windows installer object.
Dim installer : Set installer = Nothing
Set installer = Wscript.CreateObject( "WindowsInstaller.Installer" )

' Open the MSI database.
If Not bSilent Then WScript.Echo ""
If Not bSilent Then WScript.Echo "Customizing """ & szDatabasePath & """..."
Dim database : Set database = installer.OpenDatabase( szDatabasePath, openMode )

' Open the source XML file.
Set oDoc = CreateObject( "MSXML2.DOMDocument.6.0" )
oDoc.load( szCustomizationXMLFile )
Dim oNodeList
Dim oNode
Dim oValueNode

' Set configuration flags based on XML file.
Dim bVaultConnections : bVaultConnections = GetBooleanNode( oDoc, "/root/VaultConnections" )
Dim bServerConnections : bServerConnections = GetBooleanNode( oDoc, "/root/ServerConnections" )

' Get platform.
Dim szPlatform : szPlatform = GetProperty( database, "MPackagePlatform", "x86" )

' Client only?
Dim bClientOnly : bClientOnly = CBool( GetProperty( database, "M_CLIENTONLY", False ) )

' Client and server tools only?
Dim bClientAndServerToolsOnly : bClientAndServerToolsOnly = CBool( GetProperty( database, "M_CLIENTANDSERVERTOOLSONLY", False ) )

' Get version number.
Dim szProductVersion : szProductVersion = GetProperty( database, "ProductVersion", "" )

' Change product name if overridden in the XML file. Also update shortcuts and programs menu folder name.
Set oNode = oDoc.selectSingleNode( "/root/ProductName" )
If Not oNode Is Nothing Then
	Dim szProductName : szProductName = oNode.text
	InsertOrUpdateProperty database, "ProductName", szProductName
	If Not bSilent Then WScript.Echo ""
	If Not bSilent Then WScript.Echo "Product name: " & szProductName

    ' Update shortcuts and programs menu folder name with the new product name.
    UpdateShortcuts database, szProductName
    UpdateProgramsMenuFolderName database, szProductName
End If

' Change Edition ID if overridden in the XML file.
Set oNode = oDoc.selectSingleNode( "/root/EditionID" )
If Not oNode Is Nothing Then
	Dim szEditionID : szEditionID = oNode.text
	InsertOrUpdateProperty database, "MEditionID", szEditionID
	If Not bSilent Then WScript.Echo ""
	If Not bSilent Then WScript.Echo "Edition ID: " & szEditionID
End If

' Change edition suffix if overridden in the XML file.
Set oNode = oDoc.selectSingleNode( "/root/EditionSuffix" )
If Not oNode Is Nothing Then
	Dim szEditionSuffix : szEditionSuffix = oNode.text
	InsertOrUpdateProperty database, "MEditionSuffix", szEditionSuffix
	If Not bSilent Then WScript.Echo ""
	If Not bSilent Then WScript.Echo "Edition Suffix: " & szEditionSuffix
End If

' Prepare for adding registry entries.
Dim iVC : iVC = 0
Dim szKeyName : szKeyName = ""
Dim szValueName : szValueName = ""
Dim szValueData : szValueData = ""

' SETUP SETTINGS.
If Not bSilent Then WScript.Echo ""
If Not bSilent Then WScript.Echo "SETUP SETTINGS"
If Not bSilent Then WScript.Echo ""

' Desktop icons options.
Set oNode = oDoc.selectSingleNode( "/root/Setup/NoDesktopIcons" )
If Not oNode Is Nothing Then

	' Do not install any desktop icons.
	If Not bSilent Then WScript.Echo "Do not install desktop icons"
	ExecQuery database, "DELETE FROM `Shortcut` WHERE `Directory_` = 'DesktopFolder' "

End If

' CanInstallOlder option.
Set oNode = oDoc.selectSingleNode( "/root/Setup/CanInstallOlder" )
If Not oNode Is Nothing Then

	' Set the M_CAN_INSTALL_OLDER property to 1.
	If Not bSilent Then WScript.Echo "Allow installing an older version in silent mode"
	InsertOrUpdateProperty database, "M_CAN_INSTALL_OLDER", "1"

End If

' RemoveAllPreviousVersions option.
Set oNode = oDoc.selectSingleNode( "/root/Setup/RemoveAllPreviousVersions" )
If Not oNode Is Nothing Then

	' Set the M_REMOVE_ALL_PREVIOUS_VERSIONS property to 1.
	If Not bSilent Then WScript.Echo "Completely uninstall any older versions of M-Files on the computer"
	InsertOrUpdateProperty database, "M_REMOVE_ALL_PREVIOUS_VERSIONS", "1"

End If

' COMMON SETTINGS.
If Not bSilent Then WScript.Echo ""
If Not bSilent Then WScript.Echo "COMMON SETTINGS"
If Not bSilent Then WScript.Echo ""

' Checking for automatic updates.
Set oNode = oDoc.selectSingleNode( "/root/Common/AutomaticUpdates/CheckForUpdates" )
If Not oNode Is Nothing Then

	' Enable or disable automatic updates.
	If Not bSilent Then WScript.Echo "Checking for automatic updates: " & oNode.text
	szKeyName = "SOFTWARE\Motive\M-Files\[MVERSIONSTRING]\Common\MFAUClient"
	AddRegEntry database, True, szPlatform, "reg_common", "reg_ver_common", szKeyName, "", "EnableUpdates", "#" & CLng( oNode.text )

End If

' Automatic updates locator server.
Set oNode = oDoc.selectSingleNode( "/root/Common/AutomaticUpdates/UpdatesServerHostName" )
If Not oNode Is Nothing Then

	' Enable or disable automatic updates.
	If Not bSilent Then WScript.Echo "Automatic updates server:       " & oNode.text
	szKeyName = "SOFTWARE\Motive\M-Files\[MVERSIONSTRING]\Common\MFAUClient"
	AddRegEntry database, True, szPlatform, "reg_common", "reg_ver_common", szKeyName, "", "LocatorHostName", oNode.text

End If

' Process custom registry entries.
ProcessCustomRegistryEntries database, oDoc, szPlatform, "Common", bSilent

' M-FILES CLIENT.
If Not bSilent Then WScript.Echo ""
If Not bSilent Then WScript.Echo "M-FILES CLIENT"
If Not bSilent Then WScript.Echo ""
iVC = 1

' Drive letter.
Set oNode = oDoc.selectSingleNode( "/root/Client/DriveLetter" )
If Not oNode Is Nothing Then

	' Enable or disable automatic updates.
	If Not bSilent Then WScript.Echo "Drive letter:                   " & oNode.text
	szKeyName = "SOFTWARE\Motive\M-Files\[MVERSIONSTRING]\Client\MFClient"
	AddRegEntry database, True, szPlatform, "reg_client", "reg_ver_client", szKeyName, "", "Drive", oNode.text

End If

' Process custom registry entries.
ProcessCustomRegistryEntries database, oDoc, szPlatform, "Client", bSilent

If bVaultConnections Then
    
    ' Specify that the installer should write vault connections to the registry.
    InsertOrUpdateProperty database, "M_VAULTCONN", "1"

    ' Specify that the vault connections in the installer should be merged with any previous vault connections
    ' that are migrated from a previous version. When the vault connections have the same name, the definitions
    ' in the installer will have precedence and will be used instead of the previous version's vault connection
    ' with the same name.
    ' 
    ' Another possible value here would be "-skipclientvaults", which would completely avoid the migration of
    ' previous version's vault connections. I.e., only the vault connections in the installer package would be applied.
    InsertOrUpdateProperty database, "M_MIGRATIONOPTIONS_CLIENT", "-mergeclientvaults"

    ' Delete existing vault connection registry entries, including the predefined single vault connection entries.
    ExecQuery database, "DELETE FROM `Registry` WHERE `Component_` = 'reg_ver_client_vaults_32' "
    ExecQuery database, "DELETE FROM `Registry` WHERE `Component_` = 'reg_ver_client_vaults_64' "

    ' Add a new keypath for the components.
    Dim szConnKey : szConnKey = ""
    Dim szConnKeyBase : szConnKeyBase = ""
    szConnKeyBase = "SOFTWARE\Motive\M-Files\[MVERSIONSTRING]\Client\MFClient\Vaults"
    AddRegEntry database, True, szPlatform, "reg_vc", "reg_ver_client_vaults", szConnKeyBase, "", "+", ""  ' The '+' name indicates that the key is to be created, if absent, when the component is installed.

    ' Update component keypaths.
    ExecQuery database, "UPDATE `Component` SET `KeyPath` = 'reg_vc_base_32' WHERE `Component` = 'reg_ver_client_vaults_32' "
    ExecQuery database, "UPDATE `Component` SET `KeyPath` = 'reg_vc_base_64' WHERE `Component` = 'reg_ver_client_vaults_64' "

    ' The "GUID" value must never be written. It needs to be generated locally on the machine by M-Files Client.
    ' Remove any such elements from the configuration.
    Set oNodeList = oDoc.selectNodes( "/root/Client/Vaults/Vault/GUID" )
    For Each oNode In oNodeList
	    oNode.parentNode.removeChild oNode
    Next

    ' Process each vault connection for M-Files Client.
    Set oNodeList = oDoc.selectNodes( "/root/Client/Vaults/Vault" )
    For Each oNode In oNodeList

	    ' Get vault connection details.
	    ' Note: Support both "@Name" and "@name" for xml-compatibility.
	    szValueName = "Name"
	    if Not oNode.selectSingleNode( "@Name" ) Is Nothing Then
	    	szConnName = oNode.selectSingleNode( "@Name" ).text
	    Else	
	    	szConnName = oNode.selectSingleNode( "@name" ).text
	    End If
	    If Not bSilent Then WScript.Echo ""
	    If Not bSilent Then WScript.Echo szValueName & ": " & Space( 30 - Len( szValueName ) ) & szConnName

	    ' Specify vault connection name.
	    szConnKey = szConnKeyBase & "\" & szConnName

	    ' Specify connection details.
	    AddRegEntry database, True, szPlatform, "reg_vc", "reg_ver_client_vaults", szConnKey, iVC, "ID", "#" & iVC
	    For Each oValueNode In oNode.childNodes

		    ' Write this value.
		    szValueName = oValueNode.nodeName
		    szValueData = oValueNode.text
		    AddRegEntry database, True, szPlatform, "reg_vc", "reg_ver_client_vaults", szConnKey, iVC, szValueName, szValueData
		    If Not bSilent Then WScript.Echo szValueName & ": " & Space( 30 - Len( szValueName ) ) & szValueData

	    Next

	    ' Increment the ID.
	    iVC = iVC + 1

    Next

End If

If Not ( bClientOnly Or bClientAndServerToolsOnly ) Then

	' M-FILES SERVER.
	If Not bSilent Then WScript.Echo ""
	If Not bSilent Then WScript.Echo "M-FILES SERVER"

	' Process custom registry entries.
	ProcessCustomRegistryEntries database, oDoc, szPlatform, "Server", bSilent

End If

If Not bClientOnly Then

	' M-FILES SERVER ADMINISTRATOR.
	If Not bSilent Then WScript.Echo ""
	If Not bSilent Then WScript.Echo "M-FILES SERVER ADMINISTRATOR"
	iVC = 1

	' Process custom registry entries.
	ProcessCustomRegistryEntries database, oDoc, szPlatform, "ServerTools", bSilent

    If bServerConnections Then
        
	    ' Modify properties.
	    InsertOrUpdateProperty database, "M_SERVERCONN", "1"

	    ' Specify that the server connections in the installer should be merged with any previous server connections
	    ' that are migrated from a previous version. When the server connections have the same name, the definitions
	    ' in the installer will have precedence and will be used instead of the previous version's server connection
	    ' with the same name.
	    ' 
	    ' Another possible value here would be "-skipserverconnections", which would completely avoid the migration of
	    ' previous version's server connections. I.e., only the server connections in the installer package would be applied.
	    InsertOrUpdateProperty database, "M_MIGRATIONOPTIONS_SERVERTOOLS", "-mergeserverconnections"

	    ' Delete existing server connection registry entries, including the predefined single server connection entries.
	    ExecQuery database, "DELETE FROM `Registry` WHERE `Component_` = 'CurrentUser' "

	    ' Add a new keypath for the components.
	    szConnKeyBase = "SOFTWARE\Motive\M-Files\[MVERSIONSTRING]\ServerTools\MFAdmin\Servers"
	    AddRegEntry database, False, szPlatform, "reg_sc", "CurrentUser", szConnKeyBase, "", "+", ""  ' The '+' name indicates that the key is to be created, if absent, when the component is installed.

	    ' Update component keypaths.
	    ExecQuery database, "UPDATE `Component` SET `KeyPath` = 'reg_sc_base_any' WHERE `Component` = 'CurrentUser' "

	    ' Process each server connection for M-Files Server Administrator.
	    Set oNodeList = oDoc.selectNodes( "/root/ServerTools/Servers/Server" )
	    For Each oNode In oNodeList

		    ' Get server connection details.
		    ' Note: Support both "@Name" and "@name" for xml-compatibility.
		    szValueName = "Name"
		    if Not oNode.selectSingleNode( "@Name" ) Is Nothing Then
		    	szConnName = oNode.selectSingleNode( "@Name" ).text
		    Else	
		    	szConnName = oNode.selectSingleNode( "@name" ).text
		    End If
		    If Not bSilent Then WScript.Echo ""
		    If Not bSilent Then WScript.Echo szValueName & ": " & Space( 30 - Len( szValueName ) ) & szConnName

		    ' Specify server connection name.
		    szConnKey = szConnKeyBase & "\" & szConnName

		    ' Specify connection details.
		    For Each oValueNode In oNode.childNodes

			    ' Write this value.
			    szValueName = oValueNode.nodeName
			    szValueData = oValueNode.text
			    AddRegEntry database, False, szPlatform, "reg_sc", "CurrentUser", szConnKey, iVC, szValueName, szValueData
			    If Not bSilent Then WScript.Echo szValueName & ": " & Space( 30 - Len( szValueName ) ) & szValueData

		    Next

		    ' Increment the ID.
		    iVC = iVC + 1

	    Next

    End If

End If

On Error GoTo 0

If Not bSilent Then WScript.Echo ""

' Create a new GUID to be used as a package code.
' We create a new typelib and use its GUID.
Dim TypeLib
Set TypeLib = CreateObject( "Scriptlet.TypeLib" )
Dim szPackageCodeGUID : szPackageCodeGUID = TypeLib.Guid
Set TypeLib = Nothing

' Change package code.
On Error Resume Next
Dim oSummaryInfo
Set oSummaryInfo = database.SummaryInformation( 100 )
oSummaryInfo.Property( 9 ) = szPackageCodeGUID
oSummaryInfo.Persist
Set oSummaryInfo = Nothing
On Error GoTo 0

' Commit changes to the MSI file.
If openMode = msiOpenDatabaseModeTransact Then database.Commit

' Free objects
Set database = Nothing
Set installer = Nothing

' Sign the file.
' This requires that the computer has the referenced digital signing certificate installed.
Dim oShell
Set oShell = CreateObject( "WScript.Shell" )
Dim iRetVal
If bSign Then
	If Not bSilent Then
		WScript.Echo "Signing """ & szDatabasePath & """..."
	End If
	Dim szCmdLine : szCmdLine = "signtool.exe sign /v " & _
						"/s my /n ""M-Files Corporation"" " & _
						"/t http://timestamp.digicert.com " & _
						"/d M-Files " & _
						"/du http://www.m-files.com " & _
						"""" & szDatabasePath & """"
	iRetVal = oShell.Run( szCmdLine, 0, True )
	If iRetVal <> 0 And Not bSilent Then
		WScript.Echo "Signing error: " & iRetVal
		WScript.Quit 2
	End If
	If iRetVal <> 0 Then
		WScript.Quit 2
	End If
End If

' Show arguments.
If Not bSilent Then
	WScript.Echo ""
	WScript.Echo "M-FILES INSTALLER CUSTOMIZED:"
	WScript.Echo ""
	WScript.Echo "Setup package:                  " & szDatabasePath
	WScript.Echo "Package code:                   " & szPackageCodeGUID
	WScript.Echo ""
End If

Wscript.Quit 0

' Checks for errors.
Sub CheckError

	Dim message, errRec
	If Err = 0 Then Exit Sub
	message = Err.Source & " " & Hex( Err ) & ": " & Err.Description
	If Not installer Is Nothing Then
		Set errRec = installer.LastErrorRecord
		If Not errRec Is Nothing Then message = message & vbLf & errRec.FormatText
	End If
	Fail message

End Sub

' Displays an error message and quits.
Sub Fail( message )

	If Not bSilent Then
		Wscript.Echo message
	End If
	Wscript.Quit 2

End Sub

' Processes custom registry entries in the XML file.
Sub ProcessCustomRegistryEntries( database, oDoc, szPlatform, szFeature, bSilent )

	' Determine the XML path.
	Dim szXPath : szXPath = "/root/" & szFeature & "/RegistryEntries/RegistryEntry"
	Dim szFeatureLCase : szFeatureLCase = LCase( szFeature )

	' Process custom registry entries.
	Dim iEntry : iEntry = 1
	Set oNodeList = oDoc.selectNodes( szXPath )
	For Each oNode In oNodeList

		' Get node parameters.
		szKeyName = oNode.selectSingleNode( "KeyName" ).text
		szValueName = oNode.selectSingleNode( "ValueName" ).text
		szValueData = oNode.selectSingleNode( "ValueData" ).text

		' Update the registry entry.
		DeleteAndAddRegEntry  database, True, szPlatform, "reg_custom_" & szFeatureLCase, "reg_ver_" & szFeatureLCase, szKeyName, iEntry, szValueName, szValueData		
		If Not bSilent Then WScript.Echo ""
		If Not bSilent Then WScript.Echo szKeyName & ", " & szValueName & " = " & szValueData

		' Increment the ID.
		iEntry = iEntry + 1

	Next

End Sub

' Adds a new registry entry.
Sub AddRegEntry( database, bForHKLM, szPlatform, szRegIDBase, szRegComponentBase, szConnKey, szOrdinal, szValueName, szValueData )

	' HKLM or HKCU?
	If bForHKLM Then

		' Add to either the 32-bit or 64-bit HKLM hive, depending on the package platform.
		Dim szBits : szBits = "32"
		If szPlatform = "x64" Then szBits = "64"
		ExecQuery database, GetAddRegEntryQuery( szRegIDBase, szBits, "2", szRegComponentBase & "_" & szBits, szConnKey, szOrdinal, szValueName, szValueData )

	Else

		' Add to HKCU only.
		ExecQuery database, GetAddRegEntryQuery( szRegIDBase, "any", "1", szRegComponentBase, szConnKey, szOrdinal, szValueName, szValueData )

	End If

End Sub

' Adds or updates a registry entry.
Sub DeleteAndAddRegEntry( database, bForHKLM, szPlatform, szRegIDBase, szRegComponentBase, szConnKey, szOrdinal, szValueName, szValueData )

	' HKLM or HKCU?
	Dim szBits
	Dim szRoot
	Dim szRegComponentBaseUsed
	If bForHKLM Then
		' Add to either the 32-bit or 64-bit HKLM hive, depending on the package platform.
		szBits = "32"
		If szPlatform = "x64" Then szBits = "64"
		szRoot = "2"
		szRegComponentBaseUsed = szRegComponentBase & "_" & szBits
	Else
		' Add to HKCU only.
		szBits = "any"
		szRoot = "1"
		szRegComponentBaseUsed = szRegComponentBase
	End If
			
	' Check if there is already this registry value set in this szRegIDBase. 
	Dim foundRegistryId
	foundRegistryId = FindRecordFromDB( database, szRegIDBase, szRoot, szRegComponentBaseUsed, szConnKey, szValueName )
	
	' If the registry value exists in the MSI DB already, delete it first to prevent error in inserting later.
	If Not foundRegistryId = "" Then
		ExecQuery database, GetDeleteRegEntryQuery( foundRegistryId )
	End If
	
	' Insert the registry value to the MSI DB.
	ExecQuery database, GetAddRegEntryQuery( szRegIDBase, szBits, szRoot, szRegComponentBaseUsed, szConnKey, szOrdinal, szValueName, szValueData )

End Sub

' Forms the SQL statement for adding a registry entry.
Function GetAddRegEntryQuery( szRegIDBase, szBits, szRoot, szRegComponent, szConnKey, szOrdinal, szValueName, szValueData )

	' Primary key.
	Dim szValueNameInRegID
	szValueNameInRegID = LCase( szValueName )
	If szValueNameInRegID = "+" Then szValueNameInRegID = "base"
	Dim szRegID
	szRegID = szRegIDBase & szOrdinal & "_" & szValueNameInRegID & "_" & szBits

	' Query.
	Dim query
	query = "INSERT INTO `Registry` ( `Registry`, `Root`, `Key`, `Name`, `Value`, `Component_` ) VALUES ( " & _
				"'" & szRegID & "', " & _
				"'" & szRoot & "', " & _
				"'" & szConnKey & "', " & _
				"'" & szValueName & "', " & _
				"'" & szValueData & "', " & _
				"'" & szRegComponent & "' " & _
			") "

	' Return.
	GetAddRegEntryQuery = query

End Function

' Forms the SQL statement for adding a registry entry.
Function GetDeleteRegEntryQuery( szRegistryId )

	' Delete the record using the primary key, the record id. 
	Dim query
	query = "DELETE FROM `Registry` WHERE " & _
				"`Registry` = '" & szRegistryId & "'"

	' Return the query.
	GetDeleteRegEntryQuery = query

End Function

' Executes a database query.
Sub ExecQuery( database, query )
On Error Resume Next

	' Execute the query.
	Dim view
	Set view = database.OpenView( query ) : CheckError
	view.Execute : CheckError

On Error GoTo 0
End Sub

' Returns the unique record id of the registry value, or an empty string.    
Function FindRecordFromDB( database, szRegIDBase, szRoot, szRegComponent, szConnKey, szValueName )
On Error Resume Next

	
	' Make a select query that matches to the exact fields given.
	Dim query
	query = "SELECT `Registry` FROM `Registry` WHERE " & _
				"`Root` = " & szRoot & " AND " & _
				"`Key` = '" & szConnKey & "' AND " & _
				"`Name` = '" & szValueName & "' AND " & _
				"`Component_` = '" & szRegComponent & "' " 

	' Execute the query.
	Dim view
	Set view = database.OpenView( query ) : CheckError
	view.Execute : CheckError
	
	' Loop until the register id base matches or there are no more records.
	Dim selectRec
	Set selectRec = view.Fetch
	Do While Not selectRec Is Nothing
		' In case there are many records that match, check that the szRegIDBase matches to the beginning of the record id.
		' We must match only to szRegIDBase because that finds the record even if it had a different ordinal number.
		' This is just for making sure that we return only e.g. "custom" records and not any other. 
		' At least for now it we allow customization to delete "custom" records only.
		If  szRegIDBase = Left(selectRec.StringData(1), Len(szRegIDBase)) Then Exit Do
		Set selectRec = view.Fetch
	Loop
	
	' Return the record id if any. 
	If Not selectRec Is Nothing Then 
		FindRecordFromDB = selectRec.StringData(1)
	Else
		FindRecordFromDB = ""
	End If

On Error GoTo 0
End Function

' Inserts or updates a property in the MSI database.
Sub InsertOrUpdateProperty( database, propertyname, value )

	' First delete the property in case it already exists, then insert.
	ExecQuery database, "DELETE FROM `Property` WHERE `Property` = '" & propertyname & "' "
	ExecQuery database, "INSERT INTO `Property` ( `Property`, `Value` ) VALUES ( '" & propertyname & "', '" & value & "' ) "

End Sub

' Updates the name of the shortcut folder under Start Menu / Programs.
Sub UpdateProgramsMenuFolderName( database, szProductName )

    ' The "MFiles_X.Y.Z" entry in the Directory table determines the name of our shortcut folder under Start Menu / Programs.
    ' We can affect it by modifying the default value (DefaultDir value) of that entry in the Directory table.

    ' Costruct a complete value to update.
    Dim szCompleteValue : szCompleteValue = szProductName & " (" & szProductVersion & ")"

	' Update the table.
	ExecQuery database, "UPDATE `Directory` SET `DefaultDir` = '" & szCompleteValue & "' WHERE `Directory` = 'MFiles_X.Y.Z'"

    If Not bSilent Then WScript.Echo ""
	If Not bSilent Then WScript.Echo "Shortcut folder: " & szCompleteValue

End Sub

' Updates the product name in shortcuts.
Sub UpdateShortcuts( database, szProductName )

    ' Shortcuts to be updated.
    Dim arrShortcuts 
    arrShortcuts = Array( "Shortcut_Desktop_ExploreMFiles_x64", "Shortcut_Desktop_ExploreMFiles" )

    ' A regular expression for replacing the product name. Preserve everything preceding '|'.
    Dim regexp
    Set regexp = New RegExp
    regexp.Pattern = "\|.*"

    ' Update each shortcut.
    Dim szShortcut
    For Each szShortcut In arrShortcuts
        
        ' Read the shorcut name.
        Dim szQuery : szQuery = "SELECT `Name` FROM `Shortcut` WHERE `Shortcut` = '" & szShortcut & "'"
        Dim view
	    Set view = database.OpenView( szQuery ) : CheckError
	    view.Execute : CheckError
	    Dim record
	    Set record = view.Fetch : CheckError
        If Not record Is Nothing Then

            ' Get old name.
            Dim szOldName : szOldName = record.StringData( 1 )

            ' Replace product name. '|' gets eaten by replace, so put it back.
            Dim szNewName : szNewName = regexp.Replace( szOldName, "|" & szProductName & " (" & szProductVersion & ")" )

            ' Update the table.
            ExecQuery database, "UPDATE `Shortcut` SET `Name` = '" & szNewName & "' WHERE `Shortcut` = '" & szShortcut & "'"

            If Not bSilent Then WScript.Echo ""
	        If Not bSilent Then WScript.Echo "Shortcut: " & szNewName
        End If
    Next

End Sub

' Gets the value of the specified property from the MSI database.
Function GetProperty( database, propertyname, defaultvalue )
On Error Resume Next

	' Get property.
	Dim query
	query = "SELECT `Value` FROM `Property` WHERE `Property` = '" & propertyname & "'"
	Dim view
	Set view = database.OpenView( query ) : CheckError
	view.Execute : CheckError
	Dim record
	Set record = view.Fetch : CheckError
	GetProperty = defaultvalue
	If Not record Is Nothing Then
		GetProperty = record.StringData( 1 ) : CheckError
	End If
	Set view = Nothing : CheckError

On Error GoTo 0
End Function

' Gets an XML node value as a boolean or False if the node is not found.
Function GetBooleanNode( document, szNode ) 
    
    ' Return True if the node is "True", False otherwise.
    Dim bValue : bValue = False
    Dim oXmlNode
    Set oXmlNode = document.selectSingleNode( szNode )
    If Not oXmlNode Is Nothing Then
        If oXmlNode.text = "True" Then
            bValue = True
        End If
    End If

    GetBooleanNode = bValue
    
End Function 

' Displays usage instructions.
Sub ShowUsage()

	WScript.Echo "Usage:"
	WScript.Echo "xml <source MSI file> <XML file> <target MSI file> <silent> <sign>"
	WScript.Echo ""
	WScript.Echo "Example:"
	WScript.Echo "xml ""M-Files_x86.msi"" Vaults.xml ""M-Files_x86_MyClient.msi"" False True"

End Sub
