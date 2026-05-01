#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <wchar.h>

#define IDR_WINVNC 101
#define IDR_VNCCONFIG 102
#define IDR_WM_HOOKS 103
#define IDR_WINPTHREAD 104

static int is_switch(const wchar_t* arg, const wchar_t* name)
{
  if ((arg[0] == L'-') || (arg[0] == L'/'))
    arg++;
  return _wcsicmp(arg, name) == 0;
}

static int append_text(wchar_t** buffer, size_t* used, size_t* capacity,
                       const wchar_t* text)
{
  size_t len = wcslen(text);
  if (*used + len + 1 > *capacity) {
    size_t next = (*capacity == 0) ? 256 : *capacity;
    while (*used + len + 1 > next)
      next *= 2;
    wchar_t* resized;
    if (*buffer == NULL) {
      resized = (wchar_t*)LocalAlloc(LMEM_ZEROINIT, next * sizeof(wchar_t));
    } else {
      resized = (wchar_t*)LocalReAlloc(*buffer, next * sizeof(wchar_t),
                                       LMEM_MOVEABLE | LMEM_ZEROINIT);
    }
    if (resized == NULL)
      return 0;
    *buffer = resized;
    *capacity = next;
  }
  memcpy(*buffer + *used, text, len * sizeof(wchar_t));
  *used += len;
  (*buffer)[*used] = L'\0';
  return 1;
}

static int append_quoted_arg(wchar_t** buffer, size_t* used, size_t* capacity,
                             const wchar_t* arg)
{
  if (!append_text(buffer, used, capacity, L"\""))
    return 0;

  for (const wchar_t* p = arg; *p; p++) {
    if (*p == L'"') {
      if (!append_text(buffer, used, capacity, L"\\\""))
        return 0;
    } else {
      wchar_t tmp[2] = {*p, L'\0'};
      if (!append_text(buffer, used, capacity, tmp))
        return 0;
    }
  }

  return append_text(buffer, used, capacity, L"\"");
}

static int write_resource(int id, const wchar_t* type, const wchar_t* path)
{
  HRSRC res = FindResourceW(NULL, MAKEINTRESOURCEW(id), type);
  if (res == NULL)
    return 0;

  HGLOBAL loaded = LoadResource(NULL, res);
  if (loaded == NULL)
    return 0;

  DWORD size = SizeofResource(NULL, res);
  void* data = LockResource(loaded);
  if (data == NULL)
    return 0;

  HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                            FILE_ATTRIBUTE_NORMAL, NULL);
  if (file == INVALID_HANDLE_VALUE)
    return 0;

  DWORD written = 0;
  BOOL ok = WriteFile(file, data, size, &written, NULL);
  CloseHandle(file);
  return ok && (written == size);
}

static int ensure_dir(const wchar_t* path)
{
  if (CreateDirectoryW(path, NULL))
    return 1;
  return GetLastError() == ERROR_ALREADY_EXISTS;
}

static int contains_service_registration(int argc, wchar_t** argv)
{
  for (int i = 1; i < argc; i++) {
    if (is_switch(argv[i], L"register") || is_switch(argv[i], L"service") ||
        is_switch(argv[i], L"service_run"))
      return 1;
  }
  return 0;
}

static int is_server_command(const wchar_t* arg)
{
  return (_wcsicmp(arg, L"server") == 0) || (_wcsicmp(arg, L"run") == 0) ||
         is_switch(arg, L"register") || is_switch(arg, L"unregister") ||
         is_switch(arg, L"start") || is_switch(arg, L"stop") ||
         is_switch(arg, L"status") || is_switch(arg, L"connect") ||
         is_switch(arg, L"disconnect") || is_switch(arg, L"service") ||
         is_switch(arg, L"service_run") || is_switch(arg, L"noconsole") ||
         is_switch(arg, L"help") || is_switch(arg, L"h") ||
         (_wcsicmp(arg, L"--help") == 0) || (_wcsicmp(arg, L"/?") == 0);
}

static int get_extract_dir(int persistent, wchar_t* out, DWORD out_count)
{
  wchar_t base[MAX_PATH];
  HRESULT hr;

  if (persistent) {
    hr = SHGetFolderPathW(NULL, CSIDL_COMMON_APPDATA, NULL, SHGFP_TYPE_CURRENT,
                          base);
    if (SUCCEEDED(hr)) {
      _snwprintf(out, out_count, L"%s\\TigerVNC-OneFile", base);
      out[out_count - 1] = L'\0';
      return ensure_dir(out);
    }
  }

  hr = SHGetFolderPathW(NULL, CSIDL_LOCAL_APPDATA, NULL, SHGFP_TYPE_CURRENT,
                        base);
  if (FAILED(hr)) {
    DWORD n = GetTempPathW((DWORD)(sizeof(base) / sizeof(base[0])), base);
    if (n == 0 || n >= (DWORD)(sizeof(base) / sizeof(base[0])))
      return 0;
  }

  _snwprintf(out, out_count, L"%s\\TigerVNC-OneFile", base);
  out[out_count - 1] = L'\0';
  return ensure_dir(out);
}

int WINAPI wWinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance,
                    PWSTR lpCmdLine, int nCmdShow)
{
  (void)hInstance;
  (void)hPrevInstance;
  (void)lpCmdLine;
  (void)nCmdShow;

  int argc = 0;
  wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (argv == NULL)
    return 1;

  int persistent = contains_service_registration(argc, argv);
  wchar_t dir[MAX_PATH];
  if (!get_extract_dir(persistent, dir, MAX_PATH))
    return 2;

  wchar_t winvnc[MAX_PATH];
  wchar_t config[MAX_PATH];
  wchar_t hooks[MAX_PATH];
  wchar_t pthread[MAX_PATH];
  _snwprintf(winvnc, MAX_PATH, L"%s\\winvnc4.exe", dir);
  _snwprintf(config, MAX_PATH, L"%s\\vncconfig.exe", dir);
  _snwprintf(hooks, MAX_PATH, L"%s\\wm_hooks.dll", dir);
  _snwprintf(pthread, MAX_PATH, L"%s\\libwinpthread-1.dll", dir);
  winvnc[MAX_PATH - 1] = config[MAX_PATH - 1] = L'\0';
  hooks[MAX_PATH - 1] = pthread[MAX_PATH - 1] = L'\0';

  if (!write_resource(IDR_WINVNC, RT_RCDATA, winvnc) ||
      !write_resource(IDR_VNCCONFIG, RT_RCDATA, config) ||
      !write_resource(IDR_WM_HOOKS, RT_RCDATA, hooks) ||
      !write_resource(IDR_WINPTHREAD, RT_RCDATA, pthread)) {
    MessageBoxW(NULL, L"Failed to extract embedded TigerVNC files.",
                L"TigerVNC OneFile", MB_OK | MB_ICONERROR);
    return 3;
  }

  const wchar_t* target = config;
  int first_arg = 1;
  int default_server_args = 0;

  if (argc > 1 && (_wcsicmp(argv[1], L"config") == 0)) {
    target = config;
    first_arg = 2;
  } else if (argc > 1 && is_server_command(argv[1])) {
    target = winvnc;
    first_arg = 1;
    if ((_wcsicmp(argv[1], L"server") == 0) || (_wcsicmp(argv[1], L"run") == 0)) {
      first_arg = 2;
      default_server_args = 1;
    }
  }

  wchar_t* cmd = NULL;
  size_t used = 0;
  size_t capacity = 0;

  if (!append_quoted_arg(&cmd, &used, &capacity, target))
    return 4;

  if (default_server_args) {
    if (!append_text(&cmd, &used, &capacity, L" -noconsole"))
      return 4;
  }

  if (argc > first_arg) {
    for (int i = first_arg; i < argc; i++) {
      if (!append_text(&cmd, &used, &capacity, L" ") ||
          !append_quoted_arg(&cmd, &used, &capacity, argv[i]))
        return 4;
    }
  }

  STARTUPINFOW si;
  PROCESS_INFORMATION pi;
  ZeroMemory(&si, sizeof(si));
  ZeroMemory(&pi, sizeof(pi));
  si.cb = sizeof(si);

  BOOL ok = CreateProcessW(target, cmd, NULL, NULL, FALSE, 0, NULL, dir,
                           &si, &pi);
  if (!ok) {
    wchar_t msg[512];
    _snwprintf(msg, 512, L"Failed to launch %s.\nWin32 error: %lu", target,
               GetLastError());
    msg[511] = L'\0';
    MessageBoxW(NULL, msg, L"TigerVNC OneFile", MB_OK | MB_ICONERROR);
    return 5;
  }

  WaitForSingleObject(pi.hProcess, INFINITE);
  DWORD exit_code = 0;
  GetExitCodeProcess(pi.hProcess, &exit_code);
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  LocalFree(cmd);
  LocalFree(argv);
  return (int)exit_code;
}
