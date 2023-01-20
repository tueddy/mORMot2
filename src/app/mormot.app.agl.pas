/// High-Level Angelize Logic to Manage Multiple Daemons
// - this unit is a part of the Open Source Synopse mORMot framework 2,
// licensed under a MPL/GPL/LGPL three license - see LICENSE.md
unit mormot.app.agl;

{
  *****************************************************************************

   Launch, Watch and Kill Services or Executables from a main Service Instance
    - TSynAngelizeService Sub-Service Settings and Process
    - TSynAngelize Main Service Launcher and Watcher

  *****************************************************************************
}

interface

{$I ..\mormot.defines.inc}

uses
  sysutils,
  classes,
  variants,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  mormot.core.text,
  mormot.core.buffers,
  mormot.core.datetime,
  mormot.core.threads,
  mormot.core.rtti,
  mormot.core.json,
  mormot.core.data,
  mormot.core.log,
  mormot.net.client,
  mormot.app.console,
  mormot.app.daemon;


{ ************ TSynAngelizeService Sub-Service Settings and Process }

type
  /// exception class raised by TSynAngelize
  ESynAngelize = class(ESynException);

  /// define one TSynAngelizeService action
  // - depending on the context, as "method:param" pair
  TSynAngelizeAction = type RawUtf8;
  /// define one or several TSynAngelizeService action(s)
  // - stored as a JSON array in the settings
  TSynAngelizeActions = array of TSynAngelizeAction;

  TSynAngelize = class;
  TSynAngelizeService = class;

  /// define how "start:exename" RunRedirect() is executed
  // - soReplaceEnv let "StartEnv" values fully replace the existing environment
  // - soWinJobCloseChildren will setup a Windows Job to close any child
  // process(es) when the created process quits
  TStartOptions = set of (
    soReplaceEnv,
    soWinJobCloseChildren);

  /// used to process a "start:exename" command in the background
  TSynAngelizeRunner = class(TThreadAbstract)
  protected
    fLog: TSynLogClass;
    fSender: TSynAngelize;
    fService: TSynAngelizeService;
    fRetryEvent: TSynEvent;
    fRedirect: TFileStreamEx;
    fRedirectSize: Int64;
    // copy of fService properties
    fCmd, fEnv, fWrkDir, fRedirectFileName: TFileName;
    fAbortRequested: boolean;
    fRunOptions: TRunOptions;
    procedure Execute; override;
    procedure PerformRotation;
    function OnRedirect(const text: RawByteString; pid: cardinal): boolean;
  public
    /// start the execution of a command in a background thread
    constructor Create(aSender: TSynAngelize; aLog: TSynLog;
      aService: TSynAngelizeService; const aCmd, aEnv, aWrkDir: TFileName;
      aRedirect: TFileStreamEx); reintroduce;
    /// finalize the execution
    destructor Destroy; override;
    /// abort this process (either at shutdown, or after "stop")
    procedure Abort;
    /// let Execute retry to start the process now
    procedure RetryNow;
  end;

  /// one sub-process definition as recognized by TSynAngelize
  // - TSynAngelizeAction properties will expand %abc% place-holders when needed
  // - specifies how to start, stop and watch a given sub-process
  // - main idea is to let sub-processes remain simple process, not Operating
  // System daemons/services, for a cross-platform and user-friendly experience
  TSynAngelizeService = class(TSynJsonFileSettings)
  protected
    fName: RawUtf8;
    fOwner: TSynAngelize;
    fDescription: RawUtf8;
    fRun: RawUtf8;
    fStartWorkDir: RawUtf8;
    fStartEnv: TRawUtf8DynArray;
    fStart, fStop, fWatch: TSynAngelizeActions;
    fStateMessage: RawUtf8;
    fState: TServiceState;
    fStartOptions: TStartOptions;
    fOS: TOperatingSystem;
    fLevel, fStopRunAbortTimeoutSec, fWatchDelaySec, fRetryStableSec: integer;
    fRedirectLogFile: RawUtf8;
    fRedirectLogRotateFiles, fRedirectLogRotateBytes: integer;
    fStarted: RawUtf8;
    fRunner: TSynAngelizeRunner;
    fRunnerExitCode: integer;
    fAbortExitCodes: TIntegerDynArray;
    fNextWatch: Int64;
    procedure SetState(NewState: TServiceState; const Fmt: RawUtf8;
      const Args: array of const; ResetMessage: boolean = false);
  public
    /// initialize and set the default settings
    constructor Create; override;
    /// finalize the sub-process instance
    destructor Destroy; override;
    /// the current state of the service, as retrieved during the Watch phase
    property State: TServiceState
      read fState;
    /// text associated to the current state, as generated during Watch phase
    property StateMessage: RawUtf8
      read fStateMessage;
  published
    /// computer-friendly case-insensitive identifier of this sub-service
    // - as used internally by TSynAngelize to identify this instance
    // - should be a short, if possible ASCII and pascal-compatible, identifier
    // - contains e.g. "Name": "AuthService",
    property Name: RawUtf8
      read fName write fName;
    /// some reusable parameter available as %run% place holder
    // - default is void '', but could be used to store an executable name
    // or a Windows service name, e.g. "Run":"/path/to/authservice" or
    // "Run": "MyCompanyService" or "Run":"\"c:\path to\program.exe\" param1 param2"
    // - is used as default if a "Start" "Stop" or "Watch" command has no second
    // value (e.g. ["start"] means ["start:%run%"]), or is void (e.g. "Start":[]
    // means also ["start:%run"])
    // - the easiest case is to put the path to executable here (with double
    // quotes for space within the file name), and keep "Start" "Stop" and
    // "Watch" entries as [], for a NSSM-like behavior
    property Run: RawUtf8
      read fRun write fRun;
    /// human-friendly Unicode text which could be displayed on Web or Console UI
    // - in addition to the Name short identifier
    // - contains e.g. "Name": "Authentication Service",
    property Description: RawUtf8
      read fDescription write fDescription;
    /// sub-services are started from their increasing Level
    // - allow to define dependencies between sub-services
    // - it could be a good idea to define it by increments of ten (10,20,30...),
    // so that intermediate services may be inserted easily in the rings
    // - will disable the entry if set to 0 or any negative number
    property Level: integer
      read fLevel write fLevel;
    /// this sub-service could be activated only for a given Operating System
    // - default osUnknown will run it on all systems
    // - you can specify osWindows, osOSX, osBSD, osLinux or osPOSIX
    // - or even a specific Linux distribution (instead of wider osLinux/osPOSIX) 
    property OS: TOperatingSystem
      read fOS write fOS;
    /// the action(s) executed to start the sub-process
    // - will be executed in-order
    // - could include %abc% place holders
    // - "start:/path/to/file" for starting and monitoring the process,
    // terminated with "Stop": [ "stop:/path/to/file" ] command, optionally
    // writing console output to RedirectLogFile (like NSSM)
    // - "exec:/path/to/file" for not waiting up to its ending
    // - "wait:/path/to/file" for waiting for its ending with 0 exitcode
    // - "http://127.0.0.1:8080/publish/on" for a local HTTP request
    // - "sleep:1000" e.g. for 1 second wait between steps or after start
    // - on Windows, "service:ServiceName" calls TServiceController.Start
    // - if no ':' is set, ":%run%" is assumed, e.g. "start" = "start:%run%"
    // - you can add =## to change the expected result (0 as file exitcode, 200
    // as http status) - e.g. 'http://127.0.0.1:8900/test=201'
    // - default void "Start":[] will assume executing 'start:%run%'
    property Start: TSynAngelizeActions
      read fStart write fStart;
    /// array of "name=value" pairs to be added to the "start" env variables
    // - only supported on Windows by now
    // - could include %abc% place holders
    property StartEnv: TRawUtf8DynArray
      read fStartEnv write fStartEnv;
    /// define how "start" RunRedirect() is executed
    property StartOptions: TStartOptions
      read fStartOptions write fStartOptions;
    /// optional working folder for "start" monitored process
    // - could include %abc% place holders
    property StartWorkDir: RawUtf8
      read fStartWorkDir write fStartWorkDir;
    /// the action(s) executed to stop the sub-process
    // - will be executed in-order
    // - could include %abc% place holders
    // - "exec:/path/to/file" for not waiting up to its ending
    // - "wait:/path/to/file" for waiting for its ending
    // - "stop:/path/to/file" for stopping a process monitored from a "Start":
    // [ "start:/path/to/file" ] previous command
    // - "http://127.0.0.1:8080/publish/off" for a local HTTP request
    // - "sleep:1000" e.g. for 1 second wait between steps or after stop
    // - on Windows, "service:ServiceName" calls TServiceController.Stop
    // - if no ':' is set, ":%run%" is assumed, e.g. "stop" = "stop:%run%"
    // - you can add =## but the value is ignored during stopping
    // - default void "Stop":[] will assume executing 'stop:%run%'
    property Stop: TSynAngelizeActions
      read fStop write fStop;
    /// how many seconds to wait for a process to exit after gracefull signals
    // - e.g. after Ctrl+C or WMQUIT on Windows, or SIGTERM on POSIX
    // - default is 10 seconds
    // - you may set 0 for no gracefull stop, but direct TerminateProcess/SIGKILL
    property StopRunAbortTimeoutSec: integer
      read fStopRunAbortTimeoutSec write fStopRunAbortTimeoutSec;
    /// how many seconds an exited process is considered "stable"
    // - similar to NSSM, by default it will try to restart the executable if
    // the application died without a "stop" signal, with increasing pauses
    // - this value is the number of seconds after which a process could be 
    // retried with no pausing - default is 60, i.e. one minute
    // - setting 0 to this property would disable the whole restart algorithm
    // - call "agl /retry" to restart/retry all aborted or paused service(s)
    property RetryStableSec: integer
      read fRetryStableSec write fRetryStableSec;
    /// if the process stopped with one of this exit codes, won't restart
    // - call "agl /retry" to restart/retry all aborted or paused service(s)
    property AbortExitCodes: TIntegerDynArray
      read fAbortExitCodes write fAbortExitCodes;
    // - will be executed in-order every at WatchDelaySec pace
    // - could include %abc% place holders
    // - "exec:/path/to/file" for not waiting up to its ending
    // - "wait:/path/to/file" for waiting for its ending with 0 exitcode
    // - "http://127.0.0.1:8080/publish/watchme" for a local HTTP
    // request returning 200 on status success
    // - on Windows, "service:ServiceName" calls TServiceController.State
    // - if no ':' is set, ":%run%" is assumed, e.g. "wait" = "wait:%run%"
    // - you can add =## to change the expected result (0 as file exitcode, 200
    // as http status)
    // - note that a process monitored from a "Start": [ "start:/path/to/file" ]
    // previous command is automatically watched in its monitoring thread, so
    // you can keep the default void "Watch":[] entry in this simple case
    property Watch: TSynAngelizeActions
      read fWatch write fWatch;
    /// how many seconds should we wait between each Watch method step
    // - default is 60 seconds
    // - note that all "Watch" commands of all services are done in a single
    // thread, so a too small value here may have no practical impact
    property WatchDelaySec: integer
      read fWatchDelaySec write fWatchDelaySec;
    /// redirect "start:/path/to/executable" console output to a log file
    // - could include %abc% place holders, e.g. '%agl.base%' or %agl.now%
    // - a typical value is therefore "%agl.logpath%%name%-%agl.now%.log"
    property RedirectLogFile: RawUtf8
      read fRedirectLogFile write fRedirectLogFile;
    /// how many rotate files RedirectLogFile could generate at once
    // - default 0 disable the whole rotation process
    property RedirectLogRotateFiles: integer
      read fRedirectLogRotateFiles write fRedirectLogRotateFiles;
    /// after how many bytes in RedirectLogFile rotation should occur
    // - default is 100 MB
    property RedirectLogRotateBytes: integer
      read fRedirectLogRotateBytes write fRedirectLogRotateBytes;
  end;

  /// meta-class of TSynAngelizeService
  // - so that base TSynAngelizeService class could be inherited and completed
  TSynAngelizeServiceClass = class of TSynAngelizeService;


{ ************ TSynAngelize Main Service Launcher and Watcher }

  /// define the main TSynAngelize daemon/service behavior
  TSynAngelizeSettings = class(TSynDaemonSettings)
  protected
    fFolder, fExt, fStateFile: TFileName;
    fHtmlStateFileIdentifier: RawUtf8;
    fHttpTimeoutMS, fStartTimeoutSec: integer;
  public
    /// set the default values
    constructor Create; override;
  published
    /// where the TSynAngelizeService settings are stored
    // - default is the 'services' sub-folder of the TSynAngelizeSettings
    property Folder: TFileName
      read fFolder write fFolder;
    /// the extension of the TSynAngelizeService settings files
    // - default is '.service'
    property Ext: TFileName
      read fExt write fExt;
    /// timeout in seconds for "http://....." local HTTP requests
    // - default is 200
    property HttpTimeoutMS: integer
      read fHttpTimeoutMS write fHttpTimeoutMS;
    /// the local file used to communicate the current sub-process files
    // from running daemon to the state
    // - default is a TemporaryFileName instance
    property StateFile: TFileName
      read fStateFile write fStateFile;
    /// if set, will generate a StateFile+'.html' content
    // - with a HTML page with this text as description, followed by a <table>
    // of the current services states
    // - could be served e.g. via a local nginx server over Internet (or
    // Intranet) to monitor the services state from anywhere in the world
    property HtmlStateFileIdentifier: RawUtf8
      read fHtmlStateFileIdentifier write fHtmlStateFileIdentifier;
    /// how many seconds a "Level" should wait for all its processes to start
    // - default is 30 seconds
    // - you can set to 0 to not wait for starting
    property StartTimeoutSec: integer
      read fStartTimeoutSec write fStartTimeoutSec;
  end;

  /// used to serialize the current state of the services
  // - as a local temporary binary file, for "agl --list" execution
  TSynAngelizeState = packed record
    Service: array of record
      Name: RawUtf8;
      State: TServiceState;
      Info: RawUtf8;
    end;
  end;

  /// can run a set of executables as sub-process(es) from *.service definitions
  // - agl ("angelize") is an alternative to NSSM / SRVANY / WINSW
  // - at OS level, there will be a single agl daemon or service
  // - this main agl instance will manage one or several executables as
  // sub-process(es), and act as both Launcher and WatchDog
  // - in addition to TSynDaemon command line switches, you could use /list
  // to retrieve the state of services
  TSynAngelize = class(TSynDaemon)
  protected
    fAdditionalParams: TFileName;
    fSettingsClass: TSynAngelizeServiceClass;
    fExpandLevel: byte;
    fHasWatchs: boolean;
    fServiceStarted: boolean;
    fLastUpdateServicesFromSettingsFolder: cardinal;
    fSectionName: RawUtf8;
    fService, fStarted: array of TSynAngelizeService;
    fLevels: TIntegerDynArray;
    fLastGetServicesStateFile: RawByteString;
    fWatchThread: TSynBackgroundThreadProcess;
    fRunJob: THandle; // a single Windows Job to rule them all
    // TSynDaemon command line methods
    function CustomParseCmd(P: PUtf8Char): boolean; override;
    function CustomCommandLineSyntax: string; override;
    procedure ClearServicesState;
    function LoadServicesState(out state: TSynAngelizeState): boolean;
    procedure ListServices;
    procedure NewService;
    procedure StartServices;
    procedure StopServices;
    procedure StartWatching;
    procedure WatchEverySecond(Sender: TSynBackgroundThreadProcess);
    procedure StopWatching;
    // sub-service support
    function FindService(const ServiceName: RawUtf8): TSynAngelizeService;
    function ComputeServicesStateFiles: integer;
    procedure ComputeServicesHtmlFile;
    function DoExpand(aService: TSynAngelizeService;
      const aInput: TSynAngelizeAction): TSynAngelizeAction; virtual;
    procedure DoExpandLookup(aInstance: TObject;
      var aProp: RawUtf8; const aID: RawUtf8); virtual;
    procedure DoWatch(aLog: TSynLog; aService: TSynAngelizeService;
      const aAction: TSynAngelizeAction); virtual;
  public
    /// initialize the main daemon/server redirection instance
    // - main TSynAngelizeSettings is loaded
    constructor Create(aSettingsClass: TSynAngelizeServiceClass = nil;
      aLog: TSynLogClass = nil; const aSectionName: RawUtf8 = 'Main'); reintroduce;
    /// finalize the stored information
    destructor Destroy; override;
    /// read and parse all *.service definitions from Settings.Folder
    // - as called by Start overriden method
    // - may be called before head to validate the execution settings
    // - raise ESynAngelize on invalid settings or dubious StateFile
    function LoadServicesFromSettingsFolder: integer;
    /// compute a path/action, replacing all %abc% place holders with their values
    // - TSystemPath values are available as %CommonData%, %UserData%,
    // %CommonDocuments%, %UserDocuments%, %TempFolder% and %Log%
    // - %agl.base% is the location of the agl executable
    // - %agl.now% is the current date and time, in a filename compatible format
    // - %agl.params% are the additional parameters supplied to the command line
    // - %agl.propname% is the "propname": property value in the main
    // TSynAngelizeSettings, e.g. %agl.folder% for location of the *.service files,
    // or %agl.logpath% for the/log sub-folder
    // - %propname% is the "propname": property value in the .service settings,
    // e.g. %run% is the main executable or service name as defined in "Run": "...."
    function Expand(aService: TSynAngelizeService;
      const aAction: TSynAngelizeAction): TSynAngelizeAction;
    /// overriden for proper sub-process starting
    procedure Start; override;
    /// overriden for proper sub-process stoping
    // - should do nothing if the daemon was already stopped
    procedure Stop; override;
    /// overriden for proper sub-process retry
    procedure Resume; override;
  end;


implementation


{ ************ TSynAngelizeService Sub-Service Settings and Process }

{ TSynAngelizeRunner }

constructor TSynAngelizeRunner.Create(aSender: TSynAngelize; aLog: TSynLog;
  aService: TSynAngelizeService; const aCmd, aEnv, aWrkDir: TFileName;
  aRedirect: TFileStreamEx);
begin
  fSender := aSender;
  fLog := aLog.LogClass;
  fService := aService;
  fService.fRunnerExitCode := -777;
  fService.fRunner := self;
  // fService may be set to nil: make a local copy of all RunRedirect() params
  fCmd := aCmd;
  fEnv := aEnv;
  fWrkDir := aWrkDir;
  if soWinJobCloseChildren in aService.StartOptions then
    include(fRunOptions, roWinJobCloseChildren); // just ignored on POSIX
  if not (soReplaceEnv in aService.StartOptions) then
    include(fRunOptions, roEnvAddExisting);
  fRedirect := aRedirect;
  if fRedirect <> nil then
    fRedirectFileName := fRedirect.FileName;
  fRetryEvent := TSynEvent.Create;
  FreeOnTerminate := true;
  inherited Create({suspended=}false);
end;

destructor TSynAngelizeRunner.Destroy;
begin
  Abort; // ensure fRetryEvent.WaitFor in Execute is released
  inherited Destroy;
  FreeAndNil(fRedirect);
  FreeAndNil(fRetryEvent);
end;

procedure TSynAngelizeRunner.Abort;
begin
  if (self = nil) or
     fAbortRequested then
    exit;
  fAbortRequested := true;
  fRetryEvent.SetEvent;
end;

procedure TSynAngelizeRunner.RetryNow;
begin
  if self <> nil then
    fRetryEvent.SetEvent; // unlock WaitFor(pause) below
end;

procedure TSynAngelizeRunner.Execute;
var
  log: TSynLog;
  min, pause, err: integer;
  tix, start, lastunstable: Int64;
  // some values are copied from fService to avoid most unexpected GPF
  timeout: integer;     // RetryStableSec
  sn: RawUtf8;          // Name
  se: TIntegerDynArray; // AbortExitCodes

  procedure NotifyException(E: Exception);
  begin
    log.Log(sllWarning, 'Execute % raised %', [sn, E.ClassType], self);
    fService.SetState(ssFailed, '% [%]', [E.ClassType, E.Message]);
  end;

begin
  log := fLog.Add;
  timeout := fService.RetryStableSec * 1000;
  sn := fService.Name;
  se := fService.AbortExitCodes;
  SetCurrentThreadName('run %', [sn]);
  try
    lastunstable := 0;
    repeat
      err := -7777777;
      fService.SetState(ssStarting, '%', [fCmd], {resetmessage=}true);
      start := GetTickCount64;
      try
        log.Log(sllTrace, 'Execute %: %', [sn, fCmd], self);
        // run the command in this thread, calling OnRedirect during execution
        RunRedirect(fCmd, @err, OnRedirect, INFINITE, {setresult=}false,
          fEnv, fWrkDir, fRunOptions);
        // if we reached here, the command was properly finished (or stopped)
        fService.SetState(ssStopped, 'ExitCode=%', [err]);
      except
        on E: Exception do
          NotifyException(E);
      end;
      if Terminated or
         (fService = nil) then
        break;
      fService.fRunnerExitCode := err;
      if fAbortRequested then
        break;
      if (timeout = 0) or
         IntegerScanExists(pointer(se), length(se), err) then
      begin
        // RetryStableSec=0 or AbortExitCodes[] match = no automatic retry
        log.Log(sllTrace, 'Execute %: pause forever after ExitCode=%',
          [sn, err], self);
        fService.SetState(ssPaused, 'Wait for abort or /retry', []);
        fRetryEvent.WaitForEver; // will wait for abort or /retry
      end
      else
      begin
        // restart the service
        tix := GetTickCount64;
        if tix - start < timeout then
        begin
          // it did not last RetryStableSec: seems not stable - pause and retry
          pause := 2;
          if lastunstable = 0 then
            lastunstable := tix
          else
          begin
            min := (tix - lastunstable) div 60000;
            if min > 60 then  // retry every 2 sec until 1 min
              if min < 5 then
                pause := 15   // retry every 15 sec until 5 min
              else if min > 10 then
                pause := 30   // retry every 30 sec until 10 min
              else if min > 30 then
                pause := 60   // retry every min until 30 min
              else if min > 60 then
                pause := 120  // retry every 2 min until 1 hour
              else
                pause := 240; // retry every 4 min
          end;
          fService.SetState(ssPaused, 'Wait % sec', [pause]);
          pause := pause * 1000 + integer(Random32(pause) * 100);
          // add a small random threshold to smoothen several services restart
          log.Log(sllTrace, 'Execute %: pause % after ExitCode=%',
            [sn, MilliSecToString(pause), err], self);
          fRetryEvent.WaitFor(pause);
        end
        else
        begin
          // stable for enough time: retry now, and reset increasing pauses
          lastunstable := 0;
          log.Log(sllTrace, 'Execute %: retry after ExitCode=%', [sn, err], self);
        end;
      end;
    until fAbortRequested or
          Terminated;
    log.Log(sllTrace, 'Execute %: finished', [sn], self);
  except
    on E: Exception do
      NotifyException(E);
  end;
  if fService <> nil then
    fService.fRunner := nil; // notify ended
  log.NotifyThreadEnded;   // as needed by TSynLog
end;

procedure TSynAngelizeRunner.PerformRotation;
var
  fn: array of TFileName;
  n, i, old: PtrInt;
begin
  FreeAndNil(fRedirect);
  n := fService.RedirectLogRotateFiles;
  SetLength(fn, n - 1);
  old := 0;
  for i := n - 1 downto 1 do
  begin
    fn[i - 1] := fRedirectFileName + '.' + IntToStr(i);
    if (old = 0) and
       FileExists(fn[i - 1]) then
      old := i;
  end;
  if old = n - 1 then
    DeleteFile(fn[old - 1]);            // delete e.g. 'xxx.9'
  for i := n - 2 downto 1 do
    RenameFile(fn[i - 1], fn[i]);       // e.g. 'xxx.8' -> 'xxx.9'
  RenameFile(fRedirectFileName, fn[0]); // 'xxx' -> 'xxx.1'
  fRedirect := TFileStreamEx.Create(fRedirectFileName, fmCreate); // 'xxx' 
end;

function TSynAngelizeRunner.OnRedirect(
  const text: RawByteString; pid: cardinal): boolean;
var
  i, textstart, textlen: PtrInt;
begin
  result := fAbortRequested or Terminated; // return true to quit RunRedirect
  if text = '' then
  begin
    // at startup, or idle
    if not result and
       (fService <> nil) and
       (fService.State = ssStarting) then
      fService.SetState(ssRunning, 'PID=%', [pid]);
    exit;
  end;
  //fLog.Add.Log(sllTrace, '[%]', text, self);
  // handle optional console output redirection to a file
  if (fRedirect <> nil) and
     (text <> '') then
    try
      textstart := 0;
      textlen := length(text);
      if fRedirectSize = 0 then
        fRedirectSize := fRedirect.Size
      else
        inc(fRedirectSize, textlen);
      if (fService.RedirectLogRotateFiles <> 0) and
         (fRedirectSize > fService.RedirectLogRotateBytes) then
      begin
        // need to rotate the file(s)
        fLog.Add.Log(sllDebug, 'OnRedirect: % file rotation after %',
          [fRedirectFileName, KB(fRedirectSize)], self);
        for i := textlen downto 1 do
          if PByteArray(text)[i - 1] in [10, 13] then
          begin
            fRedirect.Write(pointer(text)^, i); // write up to last LF
            textstart := i;
            dec(textlen, i);
            break;
          end;
        PerformRotation;
        fRedirectSize := textlen;
        if fAbortRequested or Terminated then
          result := true; // aborted during rotation
      end;
      // text output to log file
      fRedirect.Write(PByteArray(text)[textstart], textlen);
      //TODO: optional TSynLog format with timestamps
    except
      on E: Exception do
      begin
        fLog.Add.Log(sllWarning, 'OnRedirect: abort log writing after %',
          [E.ClassType], self);
        FreeAndNil(fRedirect);
      end;
    end;
end;


{ TSynAngelizeService }

constructor TSynAngelizeService.Create;
begin
  inherited Create;
  fWatchDelaySec := 60;
  fStopRunAbortTimeoutSec := 10;
  fRedirectLogRotateBytes := 100 shl 20; // 100MB
  fRetryStableSec := 60;
end;

destructor TSynAngelizeService.Destroy;
begin
  inherited Destroy;
  if fRunner <> nil then
  begin
    fRunner.fService := nil; // avoid GPF
    fRunner.Terminate;
    fRunner.Abort; // release and free the thread
  end;
end;

procedure TSynAngelizeService.SetState(NewState: TServiceState;
  const Fmt: RawUtf8; const Args: array of const; ResetMessage: boolean);
var
  msg: RawUtf8;
begin
  if self <> nil then
    try
      fState := NewState;
      if ResetMessage then
        fStateMessage := '';
      FormatUtf8(Fmt, Args, msg);
      if msg <> '' then
      begin
        if fStateMessage <> '' then
          fStateMessage := fStateMessage + ', ';
        fStateMessage := fStateMessage + msg;
      end;
      if fOwner <> nil then
      begin
        fOwner.fSettings.LogClass.Add.Log(
          sllTrace, 'SetState(%) [%]', [ToText(NewState)^, msg], self);
        fOwner.ComputeServicesStateFiles; // real time notification
      end;
    except
      // so that it is safe to call this method in any context
    end;
end;


{ ************ TSynAngelize Main Service Launcher and Watcher }

{ TSynAngelizeSettings }

constructor TSynAngelizeSettings.Create;
begin
  inherited Create;
  fHttpTimeoutMS := 200;
  fFolder := IncludeTrailingPathDelimiter(Executable.ProgramFilePath + 'services');
  fExt := '.service';
  fStateFile := TemporaryFileName;
end;


{ TSynAngelize }

constructor TSynAngelize.Create(aSettingsClass: TSynAngelizeServiceClass;
  aLog: TSynLogClass; const aSectionName: RawUtf8);
begin
  if aSettingsClass = nil then
    aSettingsClass := TSynAngelizeService;
  fSettingsClass := aSettingsClass;
  inherited Create(TSynAngelizeSettings, Executable.ProgramFilePath,
    Executable.ProgramFilePath,  Executable.ProgramFilePath + 'log');
  fShowExceptionWaitEnter := false; // allow silent mode
  {$ifdef OSWINDOWS}
  WindowsServiceLog := fSettings.LogClass.DoLog;
  {$endif OSWINDOWS}
  with fSettings as TSynAngelizeSettings do
    if fHtmlStateFileIdentifier = '' then // some default text
      FormatUtf8('% Current State',
        [UpperCaseU(fSettings.ServiceName)], fHtmlStateFileIdentifier);
end;

destructor TSynAngelize.Destroy;
begin
  inherited Destroy;
  RunAbortTimeoutSecs := 0; // force RunRedirect() hard termination now
  ObjArrayClear(fService);
  fSettings.Free;
  {$ifdef OSWINDOWS}
  if fRunJob <> 0 then
    CloseHandle(fRunJob);
  {$endif OSWINDOWS}
end;

// TSynDaemon command line methods

const
  AGL_CMD: array[0..5] of PAnsiChar = (
    'LIST',
    'SETTINGS',
    'NEW',
    'RETRY',
    'RESUME',
    nil);

function TSynAngelize.CustomParseCmd(P: PUtf8Char): boolean;
begin
  result := true; // the command has been identified and processed
  case IdemPPChar(P, @AGL_CMD) of
    0:
      ListServices;
    1:
      begin
        WriteCopyright;
        ConsoleWrite('Found %', [Plural('setting', LoadServicesFromSettingsFolder)]);
      end;
    2:
      NewService;
    3,
    4:
      begin
        WriteCopyright;
        {$ifdef OSWINDOWS}
        with TServiceController.CreateOpenService('', '', fSettings.ServiceName) do
          try
            ConsoleWrite('Sending SERVICE_CONTROL_CONTINUE = ', [BOOL_STR[Resume]]);
          finally
            Free;
          end;
        {$endif OSWINDOWS}
      end;
  else
    result := false; // display syntax
  end;
end;

function TSynAngelize.CustomCommandLineSyntax: string;
begin
  {$ifdef OSWINDOWS}
  result := '/list /settings /new /retry';
  {$else}
  result := '--list --settings --new';
  {$endif OSWINDOWS}
end;

// sub-service support

function TSynAngelize.FindService(const ServiceName: RawUtf8): TSynAngelizeService;
var
  i: PtrInt;
begin
  if ServiceName <> '' then
    for i := 0 to high(fService) do
      if IdemPropNameU(fService[i].Name, ServiceName) then
      begin
        result := fService[i];
        exit;
      end;
  result := nil;
end;

const
  _STATEMAGIC = $5131e3a6;

function SortByLevel(const A, B): integer; // to display by increasing Level
begin
  result := TSynAngelizeService(A).Level - TSynAngelizeService(B).Level;
  if result = 0 then
    result := StrIComp( // display by name within each level
      pointer(TSynAngelizeService(A).Name), pointer(TSynAngelizeService(B).Name));
end;

function TSynAngelize.LoadServicesFromSettingsFolder: integer;
var
  fn: TFileName;
  r: TSearchRec;
  s, exist: TSynAngelizeService;
  sas: TSynAngelizeSettings;
begin
  ObjArrayClear(fService);
  Finalize(fLevels);
  fHasWatchs := false;
  sas := fSettings as TSynAngelizeSettings;
  // browse folder for settings files and generates fService[]
  sas.Folder := IncludeTrailingPathDelimiter(sas.Folder);
  fn := sas.Folder + '*' + sas.Ext;
  if FindFirst(fn, faAnyFile - faDirectory, r) = 0 then
  begin
    repeat
      if SearchRecValidFile(r) then
      begin
        s := fSettingsClass.Create;
        s.fOwner := self;
        s.SettingsOptions := sas.SettingsOptions; // share ini/json format
        fn := sas.Folder + r.Name;
        if s.LoadFromFile(fn) and
           (s.Name <> '') then
          if s.Level > 0 then
          begin
            exist := FindService(s.Name);
            if exist <> nil then
              raise ESynAngelize.CreateUtf8(
                'GetServices: duplicated % name in % and %',
                [s.Name, s.FileName, exist.FileName]);
            // seems like a valid .service file
            ObjArrayAdd(fService, s);
            AddSortedInteger(fLevels, s.Level);
            if s.fWatch <> nil then
              fHasWatchs := true;
            s := nil; // don't Free - will be owned by fService[]
          end
          else // s.Level <= 0
            fSettings.LogClass.Add.Log(sllDebug,
              'GetServices: disabled % (Level=%)', [r.Name, s.Level], self)
        else
          raise ESynAngelize.CreateUtf8(
                  'GetServices: invalid % content', [r.Name]);
        s.Free;
      end;
    until FindNext(r) <> 0;
    FindClose(r);
  end;
  ObjArraySort(fService, SortByLevel);
  result := length(fService);
end;

procedure TSynAngelize.ComputeServicesHtmlFile;
var
  i: PtrInt;
  ident, html: RawUtf8;
  sas: TSynAngelizeSettings;
begin
  sas := fSettings as TSynAngelizeSettings;
  ident := sas.HtmlStateFileIdentifier;
  if ident = '' then
    exit;
  // generate human-friendly HTML state file
  ident := HtmlEscape(ident); // avoid ingestion
  FormatUtf8('<!DOCTYPE html><html><head><title>%</title></head>' +
    '<style>table,th,td{border:1px solid;border-collapse:collapse;padding: 10px;}</style>' +
    '<body style="font-family:verdana"><h1>%</h1><hr>' +
    '<h2>Main Service</h2><p>Change Time : %</p>' +
    '<p>Services Count : %</p><hr>' +
    '<h2>Sub Services</h2><table style="width:100%"><thead>' +
    '<tr><th style="width:15%">Name</th>' +
    '<th style="width:15%">State</th>' +
    '<th>Info</th></tr></thead><tbody>',
    [ident, ident, NowToString, length(fService)], html);
  for i := 0 to high(fService) do
    with fService[i] do
      html := FormatUtf8('%<tr><td>%</td><td>%</td><td>%</td></tr>',
        [html, HtmlEscape(Name), ToText(State)^, HtmlEscape(StateMessage)]);
  html := html + '</tbody></table></body></html>';
  FileFromString(html, sas.StateFile + '.html');
end;

function TSynAngelize.ComputeServicesStateFiles: integer;
var
  s: TSynAngelizeService;
  state: TSynAngelizeState;
  sas: TSynAngelizeSettings;
  bin: RawByteString;
  i: PtrInt;
begin
  result := length(fService);
  // compute main binary state file
  SetLength(state.Service, result);
  for i := 0 to result - 1 do
  begin
    s := fService[i];
    state.Service[i].Name := s.Name;
    state.Service[i].State := s.State;
    state.Service[i].Info := copy(s.StateMessage, 1, 80); // truncate on display
  end;
  bin := 'xxxx' + RecordSave(state, TypeInfo(TSynAngelizeState));
  PCardinal(bin)^ := _STATEMAGIC;
  if bin <> fLastGetServicesStateFile then
  begin
    // current state did change: persist on disk
    sas := fSettings as TSynAngelizeSettings;
    FileFromString(bin, sas.StateFile);
    fLastGetServicesStateFile := bin;
    ComputeServicesHtmlFile;
  end;
end;

function TSynAngelize.Expand(aService: TSynAngelizeService;
  const aAction: TSynAngelizeAction): TSynAngelizeAction;
begin
  fExpandLevel := 0;
  result := DoExpand(aService, aAction); // internal recursive method
end;

function TSynAngelize.DoExpand(aService: TSynAngelizeService;
  const aInput: TSynAngelizeAction): TSynAngelizeAction;
var
  o, i, j: PtrInt;
  id, v: RawUtf8;
begin
  result := aInput;
  o := 1;
  repeat
    i := PosEx('%', result, o);
    if i = 0 then
      exit;
    j := PosEx('%', result, i + 1);
    if j = 0 then
      exit;
    dec(j, i + 1); // j = length abc
    if j = 0 then
    begin
      delete(result, i, 1); // %% -> %
      o := i + 1;
      continue;
    end;
    id := copy(result, i + 1, j);
    delete(result, i, j + 2);
    o := i;
    i := GetEnumNameValue(TypeInfo(TSystemPath), id, true);
    if i >= 0 then
      StringToUtf8(GetSystemPath(TSystemPath(i)), v)
    else
    begin
      v := id;
      if IdemPChar(pointer(id), 'AGL.') then
      begin
        delete(v, 1, 4);
        case FindPropName(['base',
                           'now',
                           'params'], v) of
          0: // %agl.base% is the location of the agl executable
            StringToUtf8(Executable.ProgramFilePath, v);
          1: // %agl.now% is the current date/time
            v := DateTimeToFileShort(Now);
          2: // %agl.params% are the additional parameters supplied to command line
            StringToUtf8(fAdditionalParams, v);
        else
          // e.g %agl.folder% or %agl.logpath%
          DoExpandLookup(fSettings, v, id);
        end;
      end
      else
        // %toto% for the "toto": property value in the .service settings
        DoExpandLookup(aService, v, id);
      if fExpandLevel = 50 then
        raise ESynAngelize.CreateUtf8(
          'Expand: infinite recursion within %%%', ['%', id, '%']);
      inc(fExpandLevel); // to detect and avoid stack overflow error
      v := DoExpand(aService, v);
      dec(fExpandLevel);
    end;
    if v = '' then
      continue;
    insert(v, result, o);
    inc(o, length(v));
    v := '';
  until false;
end;

procedure TSynAngelize.DoExpandLookup(aInstance: TObject;
  var aProp: RawUtf8; const aID: RawUtf8);
var
  p: PRttiCustomProp;
begin
  if aInstance <> nil then
  begin
    p := Rtti.RegisterClass(aInstance).Props.Find(aProp);
    if p <> nil then
    begin
      aProp := p.Prop.GetValueText(aInstance);
      exit;
    end;
  end;
  raise ESynAngelize.CreateUtf8('Expand: unknown %%%', ['%', aID, '%']);
end;

type
  TAglContext = (
    acDoStart,
    acDoStop,
    acDoWatch
  );
  TAglAction = (
    aaExec,
    aaWait,
    aaStart,
    aaStop,
    aaHttp,
    aaHttps,
    aaSleep
    {$ifdef OSWINDOWS} ,
    aaService
    {$endif OSWINDOWS}
  );
  TAglActions = set of TAglAction;
  TAglActionDynArray = array of TAglAction;

function ToText(c: TAglContext): RawUtf8; overload;
begin
  result := GetEnumNameTrimed(TypeInfo(TAglContext), ord(c));
end;

function ToText(a: TAglAction): RawUtf8; overload;
begin
  result := GetEnumNameTrimed(TypeInfo(TAglAction), ord(a));
end;

const
  ALLOWED_DEFAULT = [aaExec, aaWait, aaHttp, aaHttps, aaSleep]
    {$ifdef OSWINDOWS} + [aaService] {$endif};
  ALLOWED_ACTIONS: array[TAglContext] of TAglActions = (
    ALLOWED_DEFAULT  + [aaStart], // doStart
    ALLOWED_DEFAULT  + [aaStop],  // doStop
    ALLOWED_DEFAULT               // doWatch
  );

function Parse(const a: TSynAngelizeAction; ctxt: TAglContext;
  out param, text: RawUtf8): TAglActionDynArray;
var
  cmd, one: RawUtf8;
  p: PUtf8Char;
  i, n: PtrInt;
begin
  result := nil;
  Split(a, ':', cmd, param); // may leave param='' e.g. for "start" -> %run%
  n := 0;
  p := pointer(cmd);
  while p <> nil do
  begin
    GetNextItem(p, ',', one);
    i := GetEnumNameValueTrimmed(TypeInfo(TAglAction), pointer(one), length(one));
    if (i < 0) or
       not (TAglAction(i) in ALLOWED_ACTIONS[ctxt]) then
      continue; // just ignore unknown or OS-unsupported 'action:'
    if n <> 0 then
      text := text{%H-} + ',';
    text := text + ToText(TAglAction(i));
    SetLength(result, n + 1);
    result[n] := TAglAction(i);
    inc(n);
  end;
end;

function Exec(Sender: TSynAngelize; Log: TSynLog; Service: TSynAngelizeService;
  Action: TAglAction; Ctxt: TAglContext; const Param: RawUtf8): boolean;
var
  ms: integer;
  p, st: RawUtf8;
  fn, lf, env, wd: TFileName;
  ls: TFileStreamEx;
  status, expectedstatus, sec: integer;
  sas: TSynAngelizeSettings;
  endtix: Int64;
  {$ifdef OSWINDOWS}
  sc: TServiceController;
  {$endif OSWINDOWS}

  procedure CheckStatus;
  begin
    case Ctxt of
      acDoStart:
        if status <> expectedstatus then
          raise ESynAngelize.CreateUtf8(
            'DoStart % % % returned % but expected %',
            [Service.Name, ToText(Action), p, status, expectedstatus]);
      acDoWatch:
        if status <> expectedstatus then
          Service.SetState(ssFailed, '% returned % but expected %',
            [ToText(Action), status, expectedstatus], {resetmessage=}true);
    end;
  end;

begin
  expectedstatus := 0; // e.g. executable file exitcode = 0 as success
  if Split(Param, '=', p, st) then
    ToInteger(st, expectedstatus);
  if p = '' then
    p := Service.Run; // "exec" = "exec:%run%" (exename or servicename)
  case Action of
    aaExec,
    aaWait,
    aaStart,
    aaStop:
      fn := NormalizeFileName(Utf8ToString(p));
    aaHttp,
    aaHttps:
      if expectedstatus = 0 then // not overriden by ToInteger()
        expectedstatus := HTTP_SUCCESS;
  end;
  sas := Sender.Settings as TSynAngelizeSettings;
  result := false;
  Status := 0;
  case Action of
    aaExec,
    aaWait:
      begin
        status := RunCommand(fn{%H-}, Action = aaWait);
        CheckStatus;
      end;
    aaStart:
      if Service.fStarted = '' then
      begin
        if Service.RedirectLogFile <> '' then
        begin
          // create log file before thread start to track file access issue
          lf := NormalizeFileName(Utf8ToString(
            Sender.Expand(Service, Service.RedirectLogFile)));
          try
            if not FileExists(lf) then
              TFileStreamEx.Create(lf, fmCreate).Free; // a new void file
            ls := TFileStreamEx.Create(lf, fmOpenReadWrite or fmShareDenyWrite);
            ls.Seek(0, soEnd); // append
            Log.Log(sllTrace, 'Start: redirecting console output to %', [lf], Sender);
          except
            on E: Exception do
            begin
              Log.Log(sllWarning, 'Start: % when redirecting output to %',
                [E.ClassType, lf], Sender);
              ls := nil;
            end;
          end;
        end
        else
          ls := nil;
        if Service.StartEnv <> nil then
          env := Utf8ToString(Sender.Expand(Service,
            RawUtf8ArrayToCsv(Service.StartEnv, #0) + #0#0));
        if Service.StartWorkDir <> '' then
          wd := Utf8ToString(Sender.Expand(Service, Service.StartWorkDir));
        TSynAngelizeRunner.Create(Sender, Log, Service, fn, env, wd, ls);
        ObjArrayAdd(Sender.fStarted, Service); // for caller to wait for this level
        Service.fStarted := p;        
      end
      else
        raise ESynAngelize.CreateUtf8(
          '%: only a single "start" is allowed per service', [Service.Name]);
    aaStop:
      if Service.fStarted <> '' then     
        if p = Service.fStarted then
          if Service.fRunner <> nil then
          begin
            sec := Service.StopRunAbortTimeoutSec;
            RunAbortTimeoutSecs := sec;
            Service.fRunner.Abort; // set "stop" flag for OnRedirect()
            Service.SetState(ssStopping, '', []);
            if sec <= 0 then
              sec := 1 // wait at least one second for TerminateProcess/SIGKILL
            else
              sec := sec * 3; // wait up to 3 gracefull ending phases
            Log.Log(sllTrace, 'Stop: % wait for ending up to % sec', [p, sec], Sender);
            endtix := GetTickCount64 + sec * 1000;
            repeat
              SleepHiRes(10);
              if Service.fRunner = nil then
                break;
               if GetTickCount64 > endtix then
               begin
                 Log.Log(sllWarning, 'Stop: % timeout', [p], Sender);
                 break;
               end;
            until false;
            Log.Log(sllTrace, 'Stop: % ExitCode=%',
              [p, Service.fRunnerExitCode], Sender);
            Service.fStarted := '';
          end
          else
            // may happen if there is no auto-restart mode
            Log.Log(sllDebug, 'Stop: % with nothing running', [p], Sender)
        else
          raise ESynAngelize.CreateUtf8('% "stop:%" does not match "start:%"',
            [Service.Name, p, Service.fStarted]);
    aaHttp,
    aaHttps:
      begin
        if Action = aaHttps then
          p := 'https:' + p
        else
          p := 'http:' + p; // was trimmed by Parse()=aaHttp
        HttpGet(p, '', nil, false, @status, sas.HttpTimeoutMS);
        CheckStatus;
      end;
    aaSleep:
      if ToInteger(Param, ms) then
        Sleep(ms)
      else
        exit;
    {$ifdef OSWINDOWS}
    aaService:
      begin
        sc := TServiceController.CreateOpenService('', '', p);
        try
          case Ctxt of
            acDoStart:
              sc.Start([]);
            acDoStop:
              sc.Stop;
          end;
          Service.SetState(sc.State,
            'As Windows Service "%"', [p], {resetmessage=}true);
        finally
          sc.Free;
        end;
      end;
    {$endif OSWINDOWS}
  else
    raise ESynAngelize.CreateUtf8('Unexpected %', [ord(Action)]); // paranoid
  end;
  result := true;
end;

procedure DoOne(Sender: TSynAngelize; Log: TSynLog; Service: TSynAngelizeService;
  Ctxt: TAglContext; const Action: TSynAngelizeAction);
var
  a: PtrInt;
  aa: TAglActionDynArray;
  param, text: RawUtf8;
begin
  aa := Parse(Action, Ctxt, param, text);
  param := Sender.Expand(Service, param);
  Log.Log(sllDebug, '% %: % as [%] %',
    [ToText(Ctxt), Service.Name, Action, text, param], Sender);
  for a := 0 to high(aa) do
    if Exec(Sender, Log, Service, aa[a], Ctxt, param) then
      break;
end;

procedure TSynAngelize.DoWatch(aLog: TSynLog;
  aService: TSynAngelizeService; const aAction: TSynAngelizeAction);
begin
  aService.fState := ssErrorRetrievingState;
  aService.fStateMessage := '';
  DoOne(self, aLog, aService, acDoWatch, aAction);
  aLog.Log(sllTrace, 'DoWatch % % = % [%]', [aService.Name,
    aAction, ToText(aService.State)^, aService.StateMessage], self);
end;

procedure TSynAngelize.ClearServicesState;
var
  bin: RawByteString;
  sas: TSynAngelizeSettings;
begin
  sas := fSettings as TSynAngelizeSettings;
  // remove any previous local state file
  bin := StringFromFile(sas.StateFile);
  if (bin <> '') and
     (PCardinal(bin)^ <> _STATEMAGIC) then
  begin
    // this existing file is clearly invalid: store a new safe one in settings
    sas.StateFile := TemporaryFileName;
    // avoid deleting of a non valid file (may be used by malicious tools)
    raise ESynAngelize.CreateUtf8(
      'Invalid StateFile=% content', [sas.StateFile]);
  end;
  DeleteFile(sas.StateFile); // from now on, StateFile is meant to be valid
end;

function TSynAngelize.LoadServicesState(out state: TSynAngelizeState): boolean;
var
  bin: RawByteString;
begin
  result := false;
  bin := StringFromFile(TSynAngelizeSettings(fSettings).StateFile);
  if (bin = '') or
     (PCardinal(bin)^ <> _STATEMAGIC) then
    exit;
  delete(bin, 1, 4);
  result := RecordLoad(state, bin, TypeInfo(TSynAngelizeState));
end;

procedure TSynAngelize.ListServices;
var
  state: TSynAngelizeState;
  i: PtrInt;
begin
  WriteCopyright;
  if LoadServicesState(state) and
     ({%H-}state.Service <> nil) then
    for i := 0 to high(state.Service) do
      with state.Service[i] do
      begin
        ConsoleWrite('% %', [Name, ToText(State)^], SERVICESTATE_COLOR[State]);
        if Info <> '' then
          ConsoleWrite('  %', [Info], ccLightGray);
      end
  else
    ConsoleWrite('Unknown service state', ccMagenta);
  TextColor(ccLightGray);
end;

procedure TSynAngelize.NewService;
var
  sn, id, id2: RawUtf8;
  dir, fn, exe: TFileName;
  i: integer;
  sas: TSynAngelizeSettings;
  new: TSynAngelizeService;
  log: ISynLog;
begin
  // mimics nssm install <servicename> <executable> [<params>]
  log := fSettings.LogClass.Enter(self, 'NewService');
  WriteCopyright;
  if ParamCount < 3 then
    raise ESynAngelize.CreateUtf8(
      'Syntax is % /new "<servicename>" "<executable>" [<params>]',
      [Executable.ProgramName]);
  LoadServicesFromSettingsFolder; // raise ESynAngelize on error
  sn := TrimU(StringToUtf8(paramstr(2)));
  if sn = '' then
    raise ESynAngelize.CreateUtf8('/new: invalid servicename "%"', [sn]);
  if FindService(sn) <> nil then
    raise ESynAngelize.CreateUtf8('/new: duplicated servicename "%"', [sn]);
  exe := sysutils.Trim(paramstr(3));
  {$ifdef OSWINDOWS}
  if ExtractFileExt(exe) = '' then
    exe := exe + '.exe';
  {$endif OSWINDOWS}
  if exe <> '' then
    exe := ExpandFileName(exe);
  if not FileExists(exe) then
    raise ESynAngelize.CreateUtf8('/new %: missing application "%"', [sn, exe]);
  id := PropNameSanitize(sn, 'service');
  sas := fSettings as TSynAngelizeSettings;
  dir := EnsureDirectoryExists(sas.Folder);
  fn := dir + Utf8ToString(id) + sas.Ext;
  if FileExists(fn) then
    for i := 1 to 100 do
    begin
      id2 := FormatUtf8('%-%', [id, i]);
      fn := FormatString('%%%', [dir, id2, sas.Ext]);
      if not FileExists(fn) then
      begin
        id := id2;
        break;
      end;
    end;
  if fService = nil then
    sas.fServiceName := sn; // name the main service from the first added
  new := fSettingsClass.Create;
  try
    new.SettingsOptions := sas.SettingsOptions; // share ini/json format
    new.FileName := fn;
    new.fName := sn;
    new.fLevel := 10; // default level
    exe := QuoteFileName(exe); // re-quote the executable and parameters
    for i := 4 to paramcount do
      exe := exe + ' ' + QuoteFileName(paramstr(i));
    new.fRun := StringToUtf8(exe);
    new.SaveIfNeeded;
    if Assigned(log) then
      log.Log(sllDebug, 'NewService added % as %', [fn, new], self);
    ConsoleWrite('Created % file', [fn], ccLightGreen);
  finally
    new.Free;
  end;
end;

procedure TSynAngelize.StartServices;
var
  l, i, a: PtrInt;
  s: TSynAngelizeService;
  sec: integer;
  endtix: Int64;
  log: ISynLog;
  one: TSynLog;
begin
  log := fSettings.LogClass.Enter(self, 'StartServices');
  if Assigned(log) then
    one := log.Instance
  else
    one := nil;
  {$ifdef OSWINDOWS}
  // initialize a main Windows Job to kill all sub-process when main is killed
  if fRunJob = 0 then
  begin
    fRunJob := CreateJobToClose(GetCurrentProcessId);
    AssignJobToProcess(fRunJob, GetCurrentProcess, 'CloseWithParent');
    // all sub-processes will now be part of this Windows Job
    // unless soWinJobCloseChildren is set, so RunRedirect() will use the
    // CREATE_BREAKAWAY_FROM_JOB flag, then create its own new Windows Job
  end;
  {$endif OSWINDOWS}
  // start sub-services following their Level order
  for l := 0 to high(fLevels) do
  begin
    fStarted := nil;
    for i := 0 to high(fService) do
    begin
      // launch all services of this level
      s := fService[i];
      if (s.Level = fLevels[l]) and
         MatchOS(s.OS) then
      begin
        if (s.fStart = nil) and
           (s.fRun <> '') then
          // "Start":[] will assume 'start:%run%'
          DoOne(self, one, s, acDoStart, 'start')
        else
          // execute all "Start":[...,...,...] actions
          for a := 0 to high(s.fStart) do
            // any exception on DoOne() should break the starting
            DoOne(self, one, s, acDoStart, s.fStart[a]);
        if s.Watch <> nil then
          s.fNextWatch := GetTickCount64 + s.WatchDelaySec * 1000;
      end;
    end;
    // wait for all services of this level to be running
    sec := (fSettings as TSynAngelizeSettings).StartTimeoutSec;
    if sec > 0 then
    begin
      one.Log(sllTrace, 'StartServices: wait % sec for level #% start',
        [sec, fLevels[l]], self);
      endtix := GetTickCount64 + sec * 1000;
      for i := 0 to high(fStarted) do
      begin
        s := fStarted[i];
        while s.fState <> ssRunning do
          if GetTickCount64 > endtix then
            raise ESynAngelize.CreateUtf8(
              'StartServices timeout waiting for %', [s.Name])
          else
            SleepHiRes(10);
      end;
    end;
  end;
  ComputeServicesStateFiles; // save initial state before any watchdog
end;

procedure TSynAngelize.StopServices;
var
  l, i, a: PtrInt;
  s: TSynAngelizeService;
  sf: TFileName;
  errmsg: string;
  sas: TSynAngelizeSettings;
  log: ISynLog;
  one: TSynLog;
begin
  sas := fSettings as TSynAngelizeSettings;
  log := sas.LogClass.Enter(self, 'StopServices');
  if Assigned(log) then
    one := log.Instance
  else
    one := nil;
  // stop sub-services following their reverse Level order
  for l := high(fLevels) downto 0 do
    for i := 0 to high(fService) do
    begin
      s := fService[i];
      if s.Level = fLevels[l] then
      begin
        errmsg := '';
        if (s.fStop = nil) and
           (s.fRun <> '') then
          // "Stop":[] will assume 'stop:%run%'
          DoOne(self, one, s, acDoStop, 'stop')
        else
          // execute all "Stop":[...,...,...] actions
          for a := 0 to high(s.fStop) do
          try
            DoOne(self, one, s, acDoStop, s.fStop[a]);
          except
            on E: Exception do
            begin
              // any exception should continue the stopping
              one.Log(sllWarning, 'StopServices: DoStop(%,%) failed as %',
                [s.Name, s.fStop[a], E.ClassType], self);
              FormatString(' raised %: %', [E.ClassType, E.Message], errmsg);
            end;
          end;
        s.SetState(ssStopped, 'Shutdown%', [errmsg]);
      end;
    end;
  // finalize state files
  ComputeServicesHtmlFile;
  sf := sas.StateFile;
  if sf <> '' then
  begin
    one.Log(sllTrace, 'StopServices: Delete %', [sf], self);
    DeleteFile(sf); // delete binary, but not .html (marked all stopped)
  end;
end;

procedure TSynAngelize.StartWatching;
var
  log: TSynLog;
begin
  log := fSettings.LogClass.Add;
  if fHasWatchs then
  begin
    log.Log(sllTrace, 'StartWatching', self);
    fWatchThread := TSynBackgroundThreadProcess.Create('watchdog',
      WatchEverySecond, 1000, nil, log.Family.OnThreadEnded);
  end
  else
    log.Log(sllTrace, 'StartWatching: no need to watch', self);
end;

procedure TSynAngelize.WatchEverySecond(Sender: TSynBackgroundThreadProcess);
var
  i, a: PtrInt;
  tix: Int64;
  s: TSynAngelizeService;
  log: ISynLog;
  one: TSynLog;
begin
  // note that a process monitored from a "Start": [ "start:/path/to/file" ]
  // previous command is watched in its monitoring thread, not here
  one := nil;
  tix := GetTickCount64;
  for i := 0 to high(fService) do
  begin
    s := fService[i];
    if (s.fNextWatch = 0) or
       (tix < s.fNextWatch) then
      continue;
    if log = nil then
    begin
      log := fSettings.LogClass.Enter(self, 'WatchEverySecond');
      if Assigned(log) then
        one := log.Instance;
    end;
    // execute all "Watch":[...,...,...] actions
    for a := 0 to high(s.fWatch) do
      try
        DoWatch(one, s, s.fWatch[a]);
      except
        on E: Exception do // any exception should continue the watching
          one.Log(sllWarning, 'WatchEverySecond: DoWatch(%,%) raised %',
            [s.Name, s.fWatch[a], E.ClassType], self);
      end;
    tix := GetTickCount64; // may have changed during DoWatch() progress
    s.fNextWatch := tix + s.WatchDelaySec * 1000;
  end;
end;

procedure TSynAngelize.StopWatching;
begin
  if fWatchThread <> nil then
    try
      with fSettings.LogClass.Enter(self, 'StopWatching') do
        FreeAndNil(fWatchThread);
    except // should always continue, even or weird issue
    end;
end;

procedure TSynAngelize.Start;
begin
  // should raise ESynAngelize on any issue, or let background work begin
  if fServiceStarted then
    exit;
  fServiceStarted := true;
  ClearServicesState;
  if fService = nil then
    LoadServicesFromSettingsFolder;
  StartServices;
  StartWatching;
end;

procedure TSynAngelize.Stop;
begin
  if not fServiceStarted then
    exit;
  fServiceStarted := false;
  StopWatching;
  StopServices;
end;

procedure TSynAngelize.Resume;
var
  i: PtrInt;
begin
  // from /retry /resume or Windows SERVICE_CONTROL_CONTINUE control
  for i := 0 to high(fService) do
    with fService[i] do
      if (fRunner <> nil) and
         (State = ssPaused) then
      begin
        ConsoleWrite('Retry %', [Name]);
        fRunner.RetryNow;
      end;
end;


end.
