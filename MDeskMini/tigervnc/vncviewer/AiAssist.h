/* Copyright (C) 2026 IMedix.
 *
 * This is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#ifndef __AIASSIST_H__
#define __AIASSIST_H__

#include <string>

namespace AiAssist {

  std::string getConfig(const char* name, const char* fallback = "");

  bool lookupErrorCode(const std::string& code,
                       std::string& result,
                       std::string& error);

}

#endif
