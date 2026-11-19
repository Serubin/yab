#pragma once
// Chromium's CodeSignCloneManager (chrome/browser/mac/code_sign_clone_manager.mm)
// copies the whole app at every start of this browser process into
//   X/<bundle id>.code_sign_clone/code_sign_clone.XXXXXX/<App>.app.bundle
// (an APFS clone with the main executable hard-linked) and deletes it from a
// helper that waits for the browser to exit. A copy whose helper never ran
// stays until the Mac restarts. Each one is a whole Yab, and its blocks are
// real space once an update replaces the app it was cloned from.
//
// This finds this app's copies that no running process can own and removes
// them, as Chromium's own manager means to (its TODO, crbug.com/343784575):
//  - a copy is made by a YabCore after that YabCore started, so one born
//    before every running YabCore of this bundle id belongs to none. Only
//    YabCore makes copies; Yab's own processes are no owners (an agent's
//    `yab mcp` is Yab and runs for hours, and would keep every copy made
//    since it started);
//  - a process run from inside a copy keeps it. The copy's YabCore is a
//    hard link to the running YabCore (that is the point of the copy), and
//    the kernel may name any of its links as a YabCore's path, an old copy's
//    too; so a path of a file with several links says nothing and is not
//    counted, only one of a single file.
// Only folders named as Chromium names them (code_sign_clone. and six
// mkdtemp characters), real directories, in the X folder dirhelper gives
// this user, are touched.
#import <Foundation/Foundation.h>
#include <ctype.h>
#include <dirent.h>
#include <limits.h>
#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <removefile.h>
#include <string>
#include <vector>

extern "C" char* _dirhelper(int which, char* buffer, size_t length);

namespace yc::clones {

// DIRHELPER_USER_LOCAL_TRANSLOCATION: /var/folders/.../X, as Chromium asks.
inline std::string TranslocationFolder() {
  char buffer[PATH_MAX];
  if (!_dirhelper(3, buffer, sizeof(buffer))) return {};
  char real[PATH_MAX];
  if (!realpath(buffer, real)) return {};
  std::string path(real);
  if (path.rfind("/private/var/folders/", 0) != 0) return {};
  while (!path.empty() && path.back() == '/') path.pop_back();
  return path;
}

// "code_sign_clone." and six of mkdtemp's characters, nothing else.
inline bool CloneName(const char* name) {
  static const char prefix[] = "code_sign_clone.";
  if (strncmp(name, prefix, sizeof(prefix) - 1) != 0) return false;
  const char* suffix = name + sizeof(prefix) - 1;
  if (strlen(suffix) != 6) return false;
  for (const char* c = suffix; *c; ++c)
    if (!(isalnum(static_cast<unsigned char>(*c)) || *c == '.' || *c == '_' || *c == '-')) return false;
  return true;
}

struct Owner {
  std::string executable;  // empty when its file has several links
  time_t started;
};

// A copy to remove: older than every owner (with `slack` seconds for the
// clock), and no owner's executable inside it.
inline bool Stale(const std::string& copy, time_t born, const std::vector<Owner>& owners, time_t slack) {
  const std::string inside = copy + "/";
  for (const Owner& owner : owners) {
    if (!owner.executable.empty() && owner.executable.rfind(inside, 0) == 0) return false;
    if (born + slack >= owner.started) return false;
  }
  return true;
}

// The executable's containing app identity, including a nested PaneCore.app.
inline std::string ContainingBundleID(const std::string& executable) {
  size_t end = std::string::npos;
  for (const char* mark : {".app/", ".app.bundle/"}) {
    size_t at = executable.rfind(mark);
    if (at != std::string::npos && (end == std::string::npos || at > end)) end = at + strlen(mark) - 1;
  }
  if (end == std::string::npos) return {};
  NSString* plist = [@(executable.substr(0, end).c_str()) stringByAppendingPathComponent:@"Contents/Info.plist"];
  NSDictionary* info = [NSDictionary dictionaryWithContentsOfFile:plist];
  NSString* id = [info[@"CFBundleIdentifier"] isKindOfClass:NSString.class] ? info[@"CFBundleIdentifier"] : nil;
  return id ? std::string(id.UTF8String) : std::string();
}

// Every running YabCore of an app with this bundle id, or of one of its
// copies: its executable and when it started. `me` must be among them, or
// the list is no list (an empty one would make every copy stale).
inline bool Owners(const std::string& bundleID, const std::string& folder, pid_t me, std::vector<Owner>& owners) {
  int count = proc_listallpids(nullptr, 0);
  if (count <= 0) return false;
  std::vector<pid_t> pids(static_cast<size_t>(count) + 64);
  count = proc_listallpids(pids.data(), static_cast<int>(pids.size() * sizeof(pid_t)));
  bool found = false;
  for (int i = 0; i < count; ++i) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (pids[i] <= 0 || proc_pidpath(pids[i], path, sizeof(path)) <= 0) continue;
    std::string executable(path);
    static const std::string core[] = {".app/Contents/MacOS/PaneCore", ".app.bundle/Contents/MacOS/PaneCore"};
    if (!executable.ends_with(core[0]) && !executable.ends_with(core[1])) continue;
    if (executable.rfind(folder + "/", 0) != 0 && ContainingBundleID(executable) != bundleID) continue;
    struct proc_bsdinfo info;
    if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) continue;
    struct stat file;
    bool single = stat(path, &file) == 0 && file.st_nlink == 1;
    owners.push_back({single ? executable : std::string(), static_cast<time_t>(info.pbi_start_tvsec)});
    found = found || pids[i] == me;
  }
  return found;
}

// This app's copies in `folder`: Chromium's names, real directories, and
// when each was made.
inline std::vector<std::pair<std::string, time_t>> Copies(const std::string& folder) {
  std::vector<std::pair<std::string, time_t>> copies;
  DIR* dir = opendir(folder.c_str());
  if (!dir) return copies;
  while (struct dirent* entry = readdir(dir)) {
    if (!CloneName(entry->d_name)) continue;
    std::string copy = folder + "/" + entry->d_name;
    struct stat info;
    if (lstat(copy.c_str(), &info) != 0 || !S_ISDIR(info.st_mode)) continue;
    copies.emplace_back(copy, info.st_birthtimespec.tv_sec);
  }
  closedir(dir);
  return copies;
}

// Removes the copies in `folder` none of `owners` can own. How many went.
inline int Remove(const std::string& folder, const std::vector<Owner>& owners, time_t slack) {
  int gone = 0;
  for (const auto& [copy, born] : Copies(folder)) {
    if (!Stale(copy, born, owners, slack)) continue;
    if (removefile(copy.c_str(), nullptr, REMOVEFILE_RECURSIVE) == 0) ++gone;
  }
  return gone;
}

// Removes this app's copies no running YabCore can own; called by a YabCore
// (`me`) as it starts, before Chromium makes its own. How many went.
inline int Sweep(const std::string& bundleID, pid_t me, time_t slack = 30) {
  if (bundleID.empty() || bundleID.find('/') != std::string::npos || bundleID[0] == '.') return 0;
  std::string base = TranslocationFolder();
  if (base.empty()) return 0;
  std::string folder = base + "/" + bundleID + ".code_sign_clone";
  if (Copies(folder).empty()) return 0;
  std::vector<Owner> owners;
  if (!Owners(bundleID, folder, me, owners)) return 0;
  return Remove(folder, owners, slack);
}

}  // namespace yc::clones
