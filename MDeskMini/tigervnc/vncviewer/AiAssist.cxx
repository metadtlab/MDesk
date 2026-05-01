/* Copyright (C) 2026 IMedix.
 *
 * This is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#ifdef HAVE_CONFIG_H
#include <config.h>
#endif

#include "AiAssist.h"

#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <sstream>
#include <vector>

#if defined(WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <winhttp.h>
#endif

namespace {

const char* DEFAULT_ERROR_SEARCH_HOST = "mdtl.co.kr";
const char* DEFAULT_ERROR_SEARCH_PATH = "/api/api_search.php?q=";

std::string trim(const std::string& value)
{
  size_t start = 0;
  size_t end = value.size();

  while ((start < end) &&
         ((value[start] == ' ') || (value[start] == '\t') ||
          (value[start] == '\r') || (value[start] == '\n')))
    start++;

  while ((end > start) &&
         ((value[end - 1] == ' ') || (value[end - 1] == '\t') ||
          (value[end - 1] == '\r') || (value[end - 1] == '\n')))
    end--;

  return value.substr(start, end - start);
}

void loadDotEnvFile(const std::string& path, std::map<std::string, std::string>& values)
{
  std::ifstream file(path.c_str());
  if (!file)
    return;

  std::string line;
  while (std::getline(file, line)) {
    if ((line.size() >= 3) &&
        ((unsigned char)line[0] == 0xef) &&
        ((unsigned char)line[1] == 0xbb) &&
        ((unsigned char)line[2] == 0xbf))
      line.erase(0, 3);

    line = trim(line);
    if (line.empty() || (line[0] == '#'))
      continue;

    size_t eq = line.find('=');
    if (eq == std::string::npos)
      continue;

    std::string key = trim(line.substr(0, eq));
    std::string value = trim(line.substr(eq + 1));
    if (key.empty())
      continue;

    if ((value.size() >= 2) &&
        (((value[0] == '"') && (value[value.size() - 1] == '"')) ||
         ((value[0] == '\'') && (value[value.size() - 1] == '\''))))
      value = value.substr(1, value.size() - 2);

    values[key] = value;
  }
}

std::map<std::string, std::string>& dotEnvValues()
{
  static std::map<std::string, std::string> values;
  static bool loaded = false;

  if (!loaded) {
    loaded = true;

    const char* explicitFile = getenv("TIGERVNC_ENV_FILE");
    if ((explicitFile != nullptr) && (explicitFile[0] != '\0'))
      loadDotEnvFile(explicitFile, values);

    loadDotEnvFile(".env", values);

    const char* onefileDir = getenv("TIGERVNC_ONEFILE_DIR");
    if ((onefileDir != nullptr) && (onefileDir[0] != '\0'))
      loadDotEnvFile(std::string(onefileDir) + "\\.env", values);

#if defined(WIN32)
    char module[MAX_PATH];
    DWORD n = GetModuleFileNameA(NULL, module, MAX_PATH);
    if ((n > 0) && (n < MAX_PATH)) {
      std::string moduleDir = module;
      size_t slash = moduleDir.find_last_of("\\/");
      if (slash != std::string::npos)
        loadDotEnvFile(moduleDir.substr(0, slash) + "\\.env", values);
    }
#endif
  }

  return values;
}

std::string configValue(const char* name, const char* fallback = "")
{
  const char* value = getenv(name);
  if ((value != nullptr) && (value[0] != '\0'))
    return value;

  std::map<std::string, std::string>& values = dotEnvValues();
  std::map<std::string, std::string>::const_iterator it = values.find(name);
  if (it != values.end() && !it->second.empty())
    return it->second;

  return fallback;
}

int configInt(const char* name, int fallback, int minValue, int maxValue)
{
  std::string value = configValue(name);
  char* end = nullptr;
  long parsed;

  if (value.empty())
    return fallback;

  parsed = strtol(value.c_str(), &end, 10);
  if (end == value.c_str())
    return fallback;
  if (parsed < minValue)
    return fallback;
  if (parsed > maxValue)
    return maxValue;

  return (int)parsed;
}

std::string urlEncode(const std::string& value)
{
  static const char hex[] = "0123456789ABCDEF";
  std::string out;

  for (size_t i = 0; i < value.size(); i++) {
    unsigned char ch = (unsigned char)value[i];

    if (((ch >= 'A') && (ch <= 'Z')) ||
        ((ch >= 'a') && (ch <= 'z')) ||
        ((ch >= '0') && (ch <= '9')) ||
        (ch == '-') || (ch == '_') || (ch == '.') || (ch == '~')) {
      out.push_back((char)ch);
    } else {
      out.push_back('%');
      out.push_back(hex[(ch >> 4) & 0x0f]);
      out.push_back(hex[ch & 0x0f]);
    }
  }

  return out;
}

void appendUtf8(unsigned codePoint, std::string& out)
{
  if (codePoint <= 0x7f) {
    out.push_back((char)codePoint);
  } else if (codePoint <= 0x7ff) {
    out.push_back((char)(0xc0 | ((codePoint >> 6) & 0x1f)));
    out.push_back((char)(0x80 | (codePoint & 0x3f)));
  } else if (codePoint <= 0xffff) {
    out.push_back((char)(0xe0 | ((codePoint >> 12) & 0x0f)));
    out.push_back((char)(0x80 | ((codePoint >> 6) & 0x3f)));
    out.push_back((char)(0x80 | (codePoint & 0x3f)));
  } else {
    out.push_back((char)(0xf0 | ((codePoint >> 18) & 0x07)));
    out.push_back((char)(0x80 | ((codePoint >> 12) & 0x3f)));
    out.push_back((char)(0x80 | ((codePoint >> 6) & 0x3f)));
    out.push_back((char)(0x80 | (codePoint & 0x3f)));
  }
}

int hexValue(char ch)
{
  if ((ch >= '0') && (ch <= '9'))
    return ch - '0';
  if ((ch >= 'a') && (ch <= 'f'))
    return ch - 'a' + 10;
  if ((ch >= 'A') && (ch <= 'F'))
    return ch - 'A' + 10;
  return -1;
}

void skipWhitespace(const std::string& json, size_t& pos)
{
  while ((pos < json.size()) &&
         ((json[pos] == ' ') || (json[pos] == '\t') ||
          (json[pos] == '\r') || (json[pos] == '\n')))
    pos++;
}

bool parseJsonStringAt(const std::string& json, size_t quote, std::string& out)
{
  if ((quote >= json.size()) || (json[quote] != '"'))
    return false;

  out.clear();

  for (size_t i = quote + 1; i < json.size(); i++) {
    char ch = json[i];

    if (ch == '"')
      return true;

    if (ch != '\\') {
      out.push_back(ch);
      continue;
    }

    if (++i >= json.size())
      return false;

    ch = json[i];
    switch (ch) {
    case '"':
    case '\\':
    case '/':
      out.push_back(ch);
      break;
    case 'b':
      out.push_back('\b');
      break;
    case 'f':
      out.push_back('\f');
      break;
    case 'n':
      out.push_back('\n');
      break;
    case 'r':
      out.push_back('\r');
      break;
    case 't':
      out.push_back('\t');
      break;
    case 'u': {
      if ((i + 4) >= json.size())
        return false;
      unsigned codePoint = 0;
      for (int n = 0; n < 4; n++) {
        int hex = hexValue(json[++i]);
        if (hex < 0)
          return false;
        codePoint = (codePoint << 4) | (unsigned)hex;
      }
      if ((codePoint >= 0xd800) && (codePoint <= 0xdbff) &&
          ((i + 6) < json.size()) &&
          (json[i + 1] == '\\') && (json[i + 2] == 'u')) {
        size_t lowPos = i + 2;
        unsigned low = 0;
        bool validLow = true;
        for (int n = 0; n < 4; n++) {
          int hex = hexValue(json[++lowPos]);
          if (hex < 0) {
            validLow = false;
            break;
          }
          low = (low << 4) | (unsigned)hex;
        }
        if (validLow && (low >= 0xdc00) && (low <= 0xdfff)) {
          codePoint = 0x10000 + ((codePoint - 0xd800) << 10) +
                      (low - 0xdc00);
          i = lowPos;
        }
      }
      appendUtf8(codePoint, out);
      break;
    }
    default:
      return false;
    }
  }

  return false;
}

bool findKeyValueStart(const std::string& json,
                       const char* key,
                       size_t start,
                       size_t& pos)
{
  std::string needle = std::string("\"") + key + "\"";
  pos = json.find(needle, start);
  if (pos == std::string::npos)
    return false;

  pos = json.find(':', pos + needle.size());
  if (pos == std::string::npos)
    return false;

  pos++;
  skipWhitespace(json, pos);
  return pos < json.size();
}

bool findJsonStringValue(const std::string& json,
                         const char* key,
                         size_t start,
                         std::string& out)
{
  size_t pos;

  if (!findKeyValueStart(json, key, start, pos))
    return false;

  return parseJsonStringAt(json, pos, out);
}

bool findJsonStringArrayValue(const std::string& json,
                              const char* key,
                              size_t start,
                              std::vector<std::string>& values)
{
  size_t pos;

  values.clear();

  if (!findKeyValueStart(json, key, start, pos))
    return false;

  if ((pos >= json.size()) || (json[pos] != '['))
    return false;

  pos++;
  while (pos < json.size()) {
    skipWhitespace(json, pos);

    if ((pos < json.size()) && (json[pos] == ']'))
      return true;

    std::string item;
    if (!parseJsonStringAt(json, pos, item))
      return false;
    values.push_back(item);

    pos++;
    while ((pos < json.size()) && (json[pos] != ',') && (json[pos] != ']'))
      pos++;
    if ((pos < json.size()) && (json[pos] == ','))
      pos++;
  }

  return false;
}

bool firstDataObjectStart(const std::string& json, size_t& objectStart, bool& empty)
{
  size_t pos;

  objectStart = std::string::npos;
  empty = false;

  if (!findKeyValueStart(json, "data", 0, pos))
    return false;

  if ((pos >= json.size()) || (json[pos] != '['))
    return false;

  pos++;
  skipWhitespace(json, pos);

  if ((pos < json.size()) && (json[pos] == ']')) {
    empty = true;
    return true;
  }

  if ((pos >= json.size()) || (json[pos] != '{'))
    return false;

  objectStart = pos;
  return true;
}

std::string formatLookupResult(const std::string& requestedCode,
                               const std::string& response)
{
  size_t objectStart;
  bool empty;

  if (!firstDataObjectStart(response, objectStart, empty))
    return "API 응답 형식을 해석할 수 없습니다.";

  if (empty)
    return "검색 결과가 없습니다.\ncode: " + requestedCode;

  std::string code;
  std::string title;
  std::string description;
  std::vector<std::string> actions;

  findJsonStringValue(response, "code", objectStart, code);
  findJsonStringValue(response, "title", objectStart, title);
  findJsonStringValue(response, "description", objectStart, description);
  findJsonStringArrayValue(response, "action", objectStart, actions);

  if (code.empty())
    code = requestedCode;

  std::ostringstream out;
  out << "code: " << code;
  if (!title.empty())
    out << "\ntitle: " << title;
  if (!description.empty())
    out << "\ndescription: " << description;
  if (!actions.empty()) {
    out << "\naction:";
    for (size_t i = 0; i < actions.size(); i++)
      out << "\n" << (i + 1) << ". " << actions[i];
  }

  return out.str();
}

#if defined(WIN32)

std::wstring utf8ToWide(const std::string& value)
{
  if (value.empty())
    return std::wstring();

  int size = MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, nullptr, 0);
  if (size <= 0)
    return std::wstring(value.begin(), value.end());

  std::wstring out(size - 1, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, &out[0], size);
  return out;
}

std::string winHttpError(const char* action)
{
  std::ostringstream out;
  out << action << " failed with WinHTTP error " << GetLastError();
  return out.str();
}

void closeHandle(HINTERNET handle)
{
  if (handle != nullptr)
    WinHttpCloseHandle(handle);
}

bool getHttps(const std::string& host,
              const std::string& path,
              const char* serviceName,
              std::string& response,
              std::string& error)
{
  HINTERNET session = nullptr;
  HINTERNET connect = nullptr;
  HINTERNET request = nullptr;
  int timeoutMs = configInt("MDESK_ERROR_SEARCH_TIMEOUT_SECONDS",
                            30, 5, 180) * 1000;

  session = WinHttpOpen(L"MDesk Device/1.0",
                        WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                        WINHTTP_NO_PROXY_NAME,
                        WINHTTP_NO_PROXY_BYPASS, 0);
  if (session == nullptr) {
    error = winHttpError("WinHttpOpen");
    return false;
  }

  WinHttpSetTimeouts(session, timeoutMs, timeoutMs, timeoutMs, timeoutMs);

  connect = WinHttpConnect(session, utf8ToWide(host).c_str(),
                           INTERNET_DEFAULT_HTTPS_PORT, 0);
  if (connect == nullptr) {
    error = winHttpError("WinHttpConnect");
    closeHandle(session);
    return false;
  }

  request = WinHttpOpenRequest(connect, L"GET", utf8ToWide(path).c_str(),
                               nullptr, WINHTTP_NO_REFERER,
                               WINHTTP_DEFAULT_ACCEPT_TYPES,
                               WINHTTP_FLAG_SECURE);
  if (request == nullptr) {
    error = winHttpError("WinHttpOpenRequest");
    closeHandle(connect);
    closeHandle(session);
    return false;
  }

  BOOL ok = WinHttpSendRequest(request,
                               WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                               WINHTTP_NO_REQUEST_DATA, 0, 0, 0);
  if (!ok) {
    error = winHttpError("WinHttpSendRequest");
    closeHandle(request);
    closeHandle(connect);
    closeHandle(session);
    return false;
  }

  ok = WinHttpReceiveResponse(request, nullptr);
  if (!ok) {
    error = winHttpError("WinHttpReceiveResponse");
    closeHandle(request);
    closeHandle(connect);
    closeHandle(session);
    return false;
  }

  DWORD status = 0;
  DWORD statusSize = sizeof(status);
  ok = WinHttpQueryHeaders(request,
                           WINHTTP_QUERY_STATUS_CODE |
                           WINHTTP_QUERY_FLAG_NUMBER,
                           WINHTTP_HEADER_NAME_BY_INDEX,
                           &status, &statusSize, WINHTTP_NO_HEADER_INDEX);
  if (!ok) {
    error = winHttpError("WinHttpQueryHeaders");
    closeHandle(request);
    closeHandle(connect);
    closeHandle(session);
    return false;
  }

  response.clear();
  while (true) {
    DWORD available = 0;
    if (!WinHttpQueryDataAvailable(request, &available)) {
      error = winHttpError("WinHttpQueryDataAvailable");
      closeHandle(request);
      closeHandle(connect);
      closeHandle(session);
      return false;
    }

    if (available == 0)
      break;

    std::string chunk(available, '\0');
    DWORD read = 0;
    if (!WinHttpReadData(request, &chunk[0], available, &read)) {
      error = winHttpError("WinHttpReadData");
      closeHandle(request);
      closeHandle(connect);
      closeHandle(session);
      return false;
    }

    response.append(chunk.data(), read);
  }

  closeHandle(request);
  closeHandle(connect);
  closeHandle(session);

  if ((status < 200) || (status >= 300)) {
    std::ostringstream out;
    out << serviceName << " API returned HTTP " << status;
    if (!response.empty())
      out << ": " << response.substr(0, 512);
    error = out.str();
    return false;
  }

  return true;
}

#endif

}

namespace AiAssist {

std::string getConfig(const char* name, const char* fallback)
{
  return configValue(name, fallback);
}

bool lookupErrorCode(const std::string& code,
                     std::string& result,
                     std::string& error)
{
  result.clear();
  error.clear();

  std::string trimmedCode = trim(code);
  if (trimmedCode.empty()) {
    error = "Error code is empty.";
    return false;
  }

#if defined(WIN32)
  std::string host = configValue("MDESK_ERROR_SEARCH_HOST",
                                 DEFAULT_ERROR_SEARCH_HOST);
  std::string path = configValue("MDESK_ERROR_SEARCH_PATH",
                                 DEFAULT_ERROR_SEARCH_PATH);
  std::string response;

  if (host.empty()) {
    error = "MDESK_ERROR_SEARCH_HOST is empty.";
    return false;
  }

  if (path.empty())
    path = DEFAULT_ERROR_SEARCH_PATH;
  if (path[0] != '/')
    path = "/" + path;

  path += urlEncode(trimmedCode);

  if (!getHttps(host, path, "MDesk error search", response, error))
    return false;

  result = formatLookupResult(trimmedCode, response);
  return true;
#else
  error = "Error code lookup is currently implemented only for Windows.";
  return false;
#endif
}

}
