#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <wchar.h>

struct payload_entry {
  int id;
  const wchar_t* name;
};

#include "vncviewer_onefile_payload.h"

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

static int ensure_dir(const wchar_t* path)
{
  if (CreateDirectoryW(path, NULL))
    return 1;
  return GetLastError() == ERROR_ALREADY_EXISTS;
}

static int get_extract_dir(wchar_t* out, DWORD out_count)
{
  wchar_t base[MAX_PATH];
  wchar_t self[MAX_PATH];
  WIN32_FILE_ATTRIBUTE_DATA attr;
  unsigned long stamp = 0;
  unsigned long size = 0;

  HRESULT hr = SHGetFolderPathW(NULL, CSIDL_LOCAL_APPDATA, NULL,
                                SHGFP_TYPE_CURRENT, base);
  if (FAILED(hr)) {
    DWORD n = GetTempPathW((DWORD)(sizeof(base) / sizeof(base[0])), base);
    if (n == 0 || n >= (DWORD)(sizeof(base) / sizeof(base[0])))
      return 0;
  }

  if (GetModuleFileNameW(NULL, self, MAX_PATH) &&
      GetFileAttributesExW(self, GetFileExInfoStandard, &attr)) {
    stamp = attr.ftLastWriteTime.dwLowDateTime;
    size = attr.nFileSizeLow;
  }

  _snwprintf(out, out_count, L"%s\\TigerVNC-Viewer-OneFile-%08lx-%08lx",
             base, stamp, size);
  out[out_count - 1] = L'\0';
  return ensure_dir(out);
}

static int get_launcher_dir(wchar_t* out, DWORD out_count)
{
  wchar_t path[MAX_PATH];
  DWORD n = GetModuleFileNameW(NULL, path, MAX_PATH);
  if (n == 0 || n >= MAX_PATH)
    return 0;

  for (wchar_t* p = path + wcslen(path); p > path; p--) {
    if ((p[-1] == L'\\') || (p[-1] == L'/')) {
      p[-1] = L'\0';
      break;
    }
  }

  wcsncpy(out, path, out_count);
  out[out_count - 1] = L'\0';
  return 1;
}

static void set_launcher_dir_env(void)
{
  wchar_t path[MAX_PATH];
  if (get_launcher_dir(path, MAX_PATH))
    SetEnvironmentVariableW(L"TIGERVNC_ONEFILE_DIR", path);
}

static void copy_launcher_env_file(const wchar_t* extract_dir)
{
  wchar_t launcher_dir[MAX_PATH];
  wchar_t src[MAX_PATH];
  wchar_t dst[MAX_PATH];

  if (!get_launcher_dir(launcher_dir, MAX_PATH))
    return;

  _snwprintf(src, MAX_PATH, L"%s\\.env", launcher_dir);
  src[MAX_PATH - 1] = L'\0';
  if (GetFileAttributesW(src) == INVALID_FILE_ATTRIBUTES)
    return;

  _snwprintf(dst, MAX_PATH, L"%s\\.env", extract_dir);
  dst[MAX_PATH - 1] = L'\0';
  CopyFileW(src, dst, FALSE);
}

static int valid_payload_name(const wchar_t* name)
{
  if (name == NULL || name[0] == L'\0')
    return 0;

  for (const wchar_t* p = name; *p; p++) {
    if (*p == L'\\' || *p == L'/' || *p == L':' || *p == L'*' ||
        *p == L'?' || *p == L'"' || *p == L'<' || *p == L'>' ||
        *p == L'|')
      return 0;
  }

  return 1;
}

static int write_resource(int id, const wchar_t* path)
{
  HRSRC res = FindResourceW(NULL, MAKEINTRESOURCEW(id), RT_RCDATA);
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

static int append_default_viewer_args(wchar_t** cmd, size_t* used,
                                      size_t* capacity)
{
  static const wchar_t* args[] = {
    L"-AutoSelect=0",
    L"-FullColor=1",
    L"-PreferredEncoding=ZRLE",
    L"-NoJPEG=1",
    L"-AlwaysCursor=1",
    L"-CursorType=HighContrast",
    L"-FitWindow=1",
  };

  for (int i = 0; i < (int)(sizeof(args) / sizeof(args[0])); i++) {
    if (!append_text(cmd, used, capacity, L" ") ||
        !append_quoted_arg(cmd, used, capacity, args[i]))
      return 0;
  }

  return 1;
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

  wchar_t dir[MAX_PATH];

  if (!get_extract_dir(dir, MAX_PATH)) {
    MessageBoxW(NULL, L"Failed to create the TigerVNC extraction folder.",
                L"TigerVNC Viewer", MB_OK | MB_ICONERROR);
    return 2;
  }

  set_launcher_dir_env();
  copy_launcher_env_file(dir);

  for (int i = 0; i < payload_count; i++) {
    if (!valid_payload_name(payloads[i].name)) {
      MessageBoxW(NULL, L"Invalid embedded TigerVNC Viewer file name.",
                  L"TigerVNC Viewer", MB_OK | MB_ICONERROR);
      return 3;
    }

    wchar_t path[MAX_PATH];
    _snwprintf(path, MAX_PATH, L"%s\\%s", dir, payloads[i].name);
    path[MAX_PATH - 1] = L'\0';

    if (!write_resource(payloads[i].id, path)) {
      wchar_t msg[1024];
      _snwprintf(msg, 1024,
                 L"Failed to extract embedded TigerVNC Viewer file:\n%s\n\n"
                 L"Close any running viewer windows and try again.\n"
                 L"Win32 error: %lu",
                 path, GetLastError());
      msg[1023] = L'\0';
      MessageBoxW(NULL, msg, L"TigerVNC Viewer", MB_OK | MB_ICONERROR);
      return 3;
    }
  }

  wchar_t viewer[MAX_PATH];
  _snwprintf(viewer, MAX_PATH, L"%s\\vncviewer.exe", dir);
  viewer[MAX_PATH - 1] = L'\0';

  if (GetFileAttributesW(viewer) == INVALID_FILE_ATTRIBUTES) {
    MessageBoxW(NULL, L"Embedded vncviewer.exe was not found.",
                L"TigerVNC Viewer", MB_OK | MB_ICONERROR);
    return 4;
  }

  wchar_t* cmd = NULL;
  size_t used = 0;
  size_t capacity = 0;

  if (!append_quoted_arg(&cmd, &used, &capacity, viewer))
    return 5;

  if (!append_default_viewer_args(&cmd, &used, &capacity))
    return 5;

  for (int i = 1; i < argc; i++) {
    if (!append_text(&cmd, &used, &capacity, L" ") ||
        !append_quoted_arg(&cmd, &used, &capacity, argv[i]))
      return 5;
  }

  STARTUPINFOW si;
  PROCESS_INFORMATION pi;
  ZeroMemory(&si, sizeof(si));
  ZeroMemory(&pi, sizeof(pi));
  si.cb = sizeof(si);

  BOOL ok = CreateProcessW(viewer, cmd, NULL, NULL, FALSE, 0, NULL, dir,
                           &si, &pi);
  if (!ok) {
    wchar_t msg[512];
    _snwprintf(msg, 512, L"Failed to launch %s.\nWin32 error: %lu", viewer,
               GetLastError());
    msg[511] = L'\0';
    MessageBoxW(NULL, msg, L"TigerVNC Viewer", MB_OK | MB_ICONERROR);
    return 6;
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
