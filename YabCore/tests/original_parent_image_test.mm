// Controlled production-boundary tests. NOT an accepted signed image/CEF proof.
#include "../src/original_caller.mm"
#include <type_traits>
#include <cstdio>
#include <cstdlib>
int main() {
  @autoreleasepool {
    using namespace yc::original_caller;
    static_assert(!std::is_default_constructible_v<OriginalParentImagePolicy>);
    static_assert(!std::is_default_constructible_v<OriginalParentImagePair>);
    static_assert(!std::is_copy_constructible_v<OriginalParentImagePair>);
#if YABCORE_COMPILED_PARENT_POLICY_VERSION != 1
    if (AcceptedOriginalParentImageIssuer::Compiled()) return 13;
#endif
    if (OriginalParentImagePolicy::Current() || Ready()) return 1;
    if (InspectOriginalParentImage({},nullptr,nullptr)) return 2;
    if (!ParentFixedTopology("/owned/a.app","/owned/a.app/Contents/MacOS/Yab",
            "/owned/a.app/Contents/MacOS/PaneCore",@"Yab")) return 3;
    if (ParentFixedTopology("/owned/a.app","/owned/a.app/Contents/MacOS/Yab",
            "/owned/a.app-other/Contents/MacOS/PaneCore",@"Yab")) return 4;
    if (ParentFixedTopology("/owned/a.app","/owned/a.app/Contents/MacOS/../Yab",
            "/owned/a.app/Contents/MacOS/PaneCore",@"../Yab")) return 5;
    char path[]="/private/tmp/yab-parent-image-XXXXXX";
    if (!mkdtemp(path)) return 6;
    NSString* root=@(path);
    struct Cleanup {
      NSString* path;
      ~Cleanup() { [NSFileManager.defaultManager removeItemAtPath:path error:nullptr]; }
    } cleanup{root};
    const std::string file=std::string(path)+"/file", alias=std::string(path)+"/alias";
    int fd=open(file.c_str(),O_CREAT|O_EXCL|O_WRONLY|O_CLOEXEC,0600);
    if (fd<0) return 7;
    ssize_t written=write(fd,"a",1); int closed=close(fd);
    if (written!=1 || closed!=0) return 8;
    auto original=ParentImageFileStamp::Read(file,false);
    if (!original || ParentImageFileStamp::Read(file,true) || ParentImageFileStamp::Read(path,false)) return 9;
    if (symlink(file.c_str(),alias.c_str())!=0 || ParentImageFileStamp::Read(alias,false)) return 10;
    fd=open(file.c_str(),O_WRONLY|O_APPEND|O_CLOEXEC);
    if (fd<0) return 11;
    written=write(fd,"b",1); closed=close(fd);
    if (written!=1 || closed!=0) return 11;
    auto changed=ParentImageFileStamp::Read(file,false);
    if (!changed || original->Same(*changed)) return 12;
    printf("PASS controlled production policy-absence/topology/native-file-stamp boundaries; signed-positive NOT_RUN\n");
    return 0;
  }
}
