// clone_sweep.h without CEF: which of Chromium's copies of the app go.
//   clang++ -std=c++20 -fobjc-arc -framework Foundation -IYabCore/src \
//     YabCore/tests/clone_sweep_test.mm -o clone-sweep-test && ./clone-sweep-test
#include "clone_sweep.h"
#include <stdio.h>
#include <sys/attr.h>

static int failures = 0;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #x); ++failures; } } while (0)

static bool Exists(const std::string& path) { struct stat s; return lstat(path.c_str(), &s) == 0; }

// The folder's birth time, as clonefile's mkdtemp folder would have it.
static void Born(const std::string& path, time_t when) {
  struct attrlist list = {};
  list.bitmapcount = ATTR_BIT_MAP_COUNT;
  list.commonattr = ATTR_CMN_CRTIME;
  struct timespec time = {when, 0};
  if (setattrlist(path.c_str(), &list, &time, sizeof(time), 0) != 0) perror(path.c_str());
}

static std::string Make(const std::string& folder, const char* name, time_t born) {
  std::string path = folder + "/" + name;
  mkdir(path.c_str(), 0700);
  mkdir((path + "/Yab.app.bundle").c_str(), 0700);
  Born(path, born);
  return path;
}

int main() {
  using namespace yc::clones;
  CHECK(CloneName("code_sign_clone.tKdILk"));
  CHECK(CloneName("code_sign_clone.a_b-c."));
  CHECK(!CloneName("code_sign_clone.tKdIL"));
  CHECK(!CloneName("code_sign_clone.tKdILkk"));
  CHECK(!CloneName("code_sign_clone.tK/ILk"));
  CHECK(!CloneName("code_sign_clone..."));
  CHECK(!CloneName("other.tKdILk"));
  CHECK(!CloneName(".."));

  char base[] = "/tmp/yab-clone-sweep-test.XXXXXX";
  CHECK(mkdtemp(base));
  std::string folder = std::string(base) + "/dev.serafim.fast.code_sign_clone";
  mkdir(folder.c_str(), 0700);
  // The browser host now owns an app inside the UI app. Its clone directory
  // and owner matching must use that nearest app, not the UI app's identity.
  NSString* outer = [@(base) stringByAppendingPathComponent:@"Yab.app/Contents"];
  NSString* inner = [outer stringByAppendingPathComponent:@"Frameworks/PaneCore.app/Contents"];
  [NSFileManager.defaultManager createDirectoryAtPath:inner withIntermediateDirectories:YES attributes:nil error:nil];
  [@{@"CFBundleIdentifier": @"dev.serafim.fast"} writeToFile:[outer stringByAppendingPathComponent:@"Info.plist"] atomically:YES];
  [@{@"CFBundleIdentifier": @"dev.serafim.fast.core"} writeToFile:[inner stringByAppendingPathComponent:@"Info.plist"] atomically:YES];
  CHECK(ContainingBundleID(std::string(outer.UTF8String) + "/MacOS/PaneCore") == "dev.serafim.fast");
  CHECK(ContainingBundleID(std::string(inner.UTF8String) + "/MacOS/PaneCore") == "dev.serafim.fast.core");
  const time_t now = ::time(nullptr);
  std::string old = Make(folder, "code_sign_clone.OLDOLD", now - 3600);
  std::string recent = Make(folder, "code_sign_clone.NEWNEW", now - 5);
  std::string near = Make(folder, "code_sign_clone.NEARBY", now - 110);
  std::string held = Make(folder, "code_sign_clone.HELDHD", now - 3600);
  std::string odd = Make(folder, "code_sign_clone.toolong", now - 3600);
  std::string other = Make(folder, "something.ABCDEF", now - 3600);
  std::string target = Make(base, "kept-target", now - 3600);
  std::string link = folder + "/code_sign_clone.LINKED";
  symlink(target.c_str(), link.c_str());
  FILE* plain = fopen((folder + "/code_sign_clone.FILEFI").c_str(), "w");
  if (plain) fclose(plain);

  // Two YabCores: one started 100 s ago (its path a hard link: says
  // nothing), one an hour and a half ago run from inside HELDHD's copy.
  std::vector<Owner> owners = {{"", now - 100}, {held + "/Yab.app.bundle/Contents/MacOS/PaneCore", now - 90}};
  CHECK(Stale(old, now - 3600, owners, 30));
  CHECK(!Stale(held, now - 3600, owners, 30));
  CHECK(!Stale(recent, now - 5, owners, 30));
  CHECK(!Stale(near, now - 110, owners, 30));  // within the clock's slack of the oldest
  CHECK(Stale(near, now - 110, owners, 5));
  // An owner older than a copy keeps it, whoever else runs.
  CHECK(!Stale(old, now - 3600, {{"", now - 7200}, {"", now}}, 30));

  int gone = Remove(folder, owners, 30);
  CHECK(gone == 1);
  CHECK(!Exists(old));
  CHECK(Exists(recent) && Exists(near) && Exists(held));
  CHECK(Exists(odd) && Exists(other));
  CHECK(Exists(link) && Exists(target + "/Yab.app.bundle"));
  CHECK(Exists(folder + "/code_sign_clone.FILEFI"));

  // No owners at all is no list: Sweep refuses it (Owners must find self);
  // a self that is not a YabCore of this bundle is not found.
  std::vector<Owner> none;
  CHECK(!Owners("dev.serafim.fast.test-nobody", folder, getpid(), none));

  removefile(base, nullptr, REMOVEFILE_RECURSIVE);
  if (failures) return 1;
  printf("clone sweep: ok\n");
  return 0;
}
