// Private original-caller implementation. Included inside its anonymous namespace.
// No public constructor/decoded policy. Normal build has no compiled issuer inputs.
// Generated ONLY as trusted build input before helper compilation. The normal
// source has no issuer/config. Nothing reads a runtime manifest/env/argv here.
#if defined(YABCORE_BUILD_HAS_PARENT_POLICY) && YABCORE_BUILD_HAS_PARENT_POLICY == 1
#include "original_parent_policy.generated.inc"
#else
#define YABCORE_COMPILED_PARENT_POLICY_VERSION 0
#endif
class AcceptedOriginalParentImageIssuer;
class OriginalParentImagePolicy final {
 public:
  static std::shared_ptr<const OriginalParentImagePolicy> Current();
  ~OriginalParentImagePolicy() { if (parent_requirement_) CFRelease(parent_requirement_); }
  OriginalParentImagePolicy(const OriginalParentImagePolicy&) = delete;
  bool Complete() const { return !text_.empty() && text_.size()<=32768 && !identifier_.empty() && identifier_.size() <= 256 &&
      leaf_.size()==64 && std::all_of(leaf_.begin(),leaf_.end(),[](char c) { return (c>='0'&&c<='9')||(c>='a'&&c<='f'); }); }
  SecRequirementRef ParentRequirement() const {
    // Called ONLY by the bounded inspector worker, never Current()/UI checks.
    std::call_once(parse_once_,[this] {
      NSString* text=@(text_.c_str());
      if (!text.length) return;
      if (SecRequirementCreateWithString((__bridge CFStringRef)text,kSecCSDefaultFlags,&parent_requirement_)!=errSecSuccess) {
        if (parent_requirement_) CFRelease(parent_requirement_);
        parent_requirement_=nullptr;
      }
    });
    return parent_requirement_;
  }
  bool MatchesParent(const std::string& identifier,const std::string& leaf) const { return identifier==identifier_ && leaf==leaf_; }
  bool MatchesHelper(const std::string& leaf) const { return leaf==leaf_; }
 private:
  friend class AcceptedOriginalParentImageIssuer;
  OriginalParentImagePolicy(std::string text,std::string identifier,std::string leaf)
      : text_(std::move(text)),identifier_(std::move(identifier)),leaf_(std::move(leaf)) {}
  mutable std::once_flag parse_once_;
  mutable SecRequirementRef parent_requirement_ = nullptr;
  const std::string text_,identifier_,leaf_;
};
class AcceptedOriginalParentImageIssuer final {
 public:
  static std::shared_ptr<const OriginalParentImagePolicy> Compiled() {
#if YABCORE_COMPILED_PARENT_POLICY_VERSION == 1
    // One immutable parsed compiled requirement. No peer self-DR is accepted.
    static const auto policy=[]()->std::shared_ptr<const OriginalParentImagePolicy> {
      // Pure bounded constants only here. Native requirement parsing occurs
      // lazily inside the original deadline-protected inspector worker below.
      auto result=std::shared_ptr<const OriginalParentImagePolicy>(new OriginalParentImagePolicy(
          kYabCompiledParentRequirement,kYabCompiledParentIdentifier,kYabCompiledParentLeafSHA256));
      return result->Complete() ? result : nullptr;
    }();
    return policy;
#else
    return {};
#endif
  }
};
std::shared_ptr<const OriginalParentImagePolicy> OriginalParentImagePolicy::Current() {
#if YABCORE_ORIGINAL_CALLER_ACCEPTED_VERSION == 1
  return AcceptedOriginalParentImageIssuer::Compiled();
#else
  return {}; // Compiled inputs cannot activate acceptedVersion0.
#endif
}
class OriginalParentImagePair final {
 public:
  OriginalParentImagePair(const OriginalParentImagePair&) = delete;
  bool Matches(const std::shared_ptr<const OriginalParentImagePolicy>& policy,
               const std::string& parent,const std::string& helper) const {
    return policy_==policy && parent_==parent && helper_==helper;
  }
 private:
  friend std::shared_ptr<Identity> InspectOriginalParentImage(
      const std::shared_ptr<const OriginalParentImagePolicy>&,const std::shared_ptr<Identity>&,
      const std::shared_ptr<Identity>&,const std::shared_ptr<const OriginalParentImagePair>&,
      std::shared_ptr<const OriginalParentImagePair>*);
  OriginalParentImagePair(std::shared_ptr<const OriginalParentImagePolicy> policy,std::string parent,std::string helper)
      : policy_(std::move(policy)),parent_(std::move(parent)),helper_(std::move(helper)) {}
  const std::shared_ptr<const OriginalParentImagePolicy> policy_;
  const std::string parent_,helper_;
};
template <typename T> struct ParentImageCF {
  ParentImageCF() = default;
  ParentImageCF(const ParentImageCF&) = delete;
  ParentImageCF& operator=(const ParentImageCF&) = delete;
  T value = nullptr;
  ~ParentImageCF() { if (value) CFRelease(value); }
};
struct ParentImageFileStamp {
  struct stat value{};
  static std::optional<ParentImageFileStamp> Read(const std::string& path, bool directory) {
    ParentImageFileStamp result;
    if (lstat(path.c_str(),&result.value) || S_ISLNK(result.value.st_mode) ||
        (directory ? !S_ISDIR(result.value.st_mode) : !S_ISREG(result.value.st_mode))) return {};
    return result;
  }
  bool Same(const ParentImageFileStamp& other) const {
    const auto& a=value;const auto& b=other.value;
    return a.st_dev==b.st_dev && a.st_ino==b.st_ino && a.st_mode==b.st_mode && a.st_size==b.st_size &&
      a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec &&
      a.st_ctimespec.tv_sec==b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec==b.st_ctimespec.tv_nsec;
  }
};
struct ParentSignedImage {
  std::string unique, identifier, team, main, leaf;
  NSDictionary* secured_info = nil;
  bool Same(const ParentSignedImage& other) const {
    return unique==other.unique && identifier==other.identifier && team==other.team && main==other.main && leaf==other.leaf;
  }
};
std::optional<std::string> ParentCanonicalFile(NSURL* url) {
  if (![url isKindOfClass:NSURL.class] || !url.isFileURL) return {};
  char canonical[PATH_MAX]{};
  const char* path=url.fileSystemRepresentation;
  if (!path || !realpath(path,canonical)) return {};
  return std::string(canonical);
}
std::optional<ParentSignedImage> ParentSigningInfo(SecStaticCodeRef code, SecCSFlags flags) {
  ParentImageCF<CFDictionaryRef> info;
  if (SecCodeCopySigningInformation(code,flags,&info.value)!=errSecSuccess || !info.value) return {};
  NSDictionary* row=(__bridge NSDictionary*)info.value;
  NSData* unique=row[(__bridge NSString*)kSecCodeInfoUnique];
  NSString* identifier=row[(__bridge NSString*)kSecCodeInfoIdentifier];
  NSString* team=row[(__bridge NSString*)kSecCodeInfoTeamIdentifier];
  NSArray* certificates=row[(__bridge NSString*)kSecCodeInfoCertificates];
  NSData* cms=row[(__bridge NSString*)kSecCodeInfoCMS];
  auto main=ParentCanonicalFile(row[(__bridge NSString*)kSecCodeInfoMainExecutable]);
  if (![unique isKindOfClass:NSData.class] || !unique.length || unique.length>64 ||
      ![identifier isKindOfClass:NSString.class] || !identifier.length || identifier.length>256 ||
      ![team isKindOfClass:NSString.class] || !team.length || team.length>128 ||
      ![certificates isKindOfClass:NSArray.class] || !certificates.count ||
      ![cms isKindOfClass:NSData.class] || !cms.length || !main) return {};
  CFTypeRef leaf=(__bridge CFTypeRef)certificates[0];
  if (!leaf || CFGetTypeID(leaf)!=SecCertificateGetTypeID()) return {};
  ParentImageCF<CFDataRef> leaf_data;
  leaf_data.value=SecCertificateCopyData((SecCertificateRef)leaf);
  if (!leaf_data.value || CFDataGetLength(leaf_data.value)<=0 || CFDataGetLength(leaf_data.value)>65536) return {};
  ParentSignedImage result;
  result.leaf=Hash(CFDataGetBytePtr(leaf_data.value),CFDataGetLength(leaf_data.value));
  const char* identifier_utf8=identifier.UTF8String; const char* team_utf8=team.UTF8String;
  if (!identifier_utf8 || !team_utf8) return {};
  result.unique=Hex(unique.bytes,unique.length);result.identifier=identifier_utf8;
  result.team=team_utf8;result.main=*main;
  id secured=row[(__bridge NSString*)kSecCodeInfoPList];
  if ([secured isKindOfClass:NSDictionary.class]) result.secured_info=secured;
  return result;
}
std::optional<ParentSignedImage> ParentDynamicImage(SecCodeRef code, SecRequirementRef requirement) {
  // CopyStaticCode's filesystem link is NOT secure by itself. Dynamic validity
  // must bracket any signing-info/static-source observation (installed SecCode.h).
  if (!code || SecCodeCheckValidity(code,kSecCSDefaultFlags,requirement)!=errSecSuccess) return {};
  auto image=ParentSigningInfo(code,kSecCSSigningInformation|kSecCSDynamicInformation);
  if (!image || SecCodeCheckValidity(code,kSecCSDefaultFlags,requirement)!=errSecSuccess) return {};
  return image;
}
std::optional<ParentSignedImage> ParentStrictStaticImage(SecStaticCodeRef code, SecRequirementRef requirement) {
  // No allow-network, resource/executable skip, relaxed signing or unsigned fallback.
  constexpr SecCSFlags flags=kSecCSStrictValidate|kSecCSCheckNestedCode|
      kSecCSCheckAllArchitectures|kSecCSRestrictSymlinks|kSecCSSingleThreaded;
  if (!code || SecStaticCodeCheckValidity(code,flags,requirement)!=errSecSuccess) return {};
  return ParentSigningInfo(code,kSecCSSigningInformation);
}
bool ParentFixedTopology(const std::string& bundle, const std::string& parent,
                         const std::string& helper, NSString* executable) {
  // Actual scripts/cef/embed.sh embeds a plain helper at this fixed path, NOT
  // a caller-configured executable, arbitrary child bundle or prefix match.
  if (!executable || !executable.length || [executable containsString:@"/"] ||
      [executable isEqual:@"."] || [executable isEqual:@".."] ||
      [executable rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange(0,1)]].location!=NSNotFound) return false;
  const std::string main=bundle+"/Contents/MacOS/"+std::string(executable.UTF8String ?: "");
  return parent==main && helper==bundle+"/Contents/MacOS/PaneCore" && parent!=helper;
}
// Snapshot validation ONLY. No continuous filesystem/renderer/image lease or
// native phase proof is returned. Policy Current() is absent, Ready stays closed.
[[maybe_unused]] std::shared_ptr<Identity> InspectOriginalParentImage(
    const std::shared_ptr<const OriginalParentImagePolicy>& policy,
    const std::shared_ptr<Identity>& captured_parent,
    const std::shared_ptr<Identity>& captured_helper,
    const std::shared_ptr<const OriginalParentImagePair>& expected_pair = {},
    std::shared_ptr<const OriginalParentImagePair>* observed_pair = nullptr) {
  if (!policy || !policy->Complete() || !captured_parent || !captured_helper ||
      captured_helper->pid!=getpid()) return {};
  SecRequirementRef requirement=policy->ParentRequirement();
  if (!requirement) return {};
  auto parent=Read(captured_parent->pid,captured_parent->audit), helper=Self();
  if (!Same(captured_parent,parent) || !Same(captured_helper,helper)) return {};
  auto p_dynamic=ParentDynamicImage(parent->dynamic,requirement);
  ParentImageCF<SecCodeRef> actual_self;
  if (SecCodeCopySelf(kSecCSDefaultFlags,&actual_self.value)!=errSecSuccess || !actual_self.value) return {};
  auto h_dynamic=ParentDynamicImage(actual_self.value,nullptr);
  if (!p_dynamic || !h_dynamic || p_dynamic->main!=parent->executable || h_dynamic->main!=helper->executable ||
      p_dynamic->identifier!=parent->identifier || h_dynamic->identifier!=helper->identifier ||
      p_dynamic->unique!=parent->unique || h_dynamic->unique!=helper->unique ||
      p_dynamic->team!=h_dynamic->team || !policy->MatchesParent(p_dynamic->identifier,p_dynamic->leaf) ||
      !policy->MatchesHelper(h_dynamic->leaf) ||
      (expected_pair && !expected_pair->Matches(policy,p_dynamic->unique,h_dynamic->unique))) return {};
  ParentImageCF<SecStaticCodeRef> parent_disk,self_disk,nested_disk;
  if (SecCodeCopyStaticCode(parent->dynamic,kSecCSDefaultFlags,&parent_disk.value)!=errSecSuccess ||
      SecCodeCopyStaticCode(actual_self.value,kSecCSDefaultFlags,&self_disk.value)!=errSecSuccess) return {};
  ParentImageCF<CFURLRef> code_path;
  if (!parent_disk.value || SecCodeCopyPath(parent_disk.value,kSecCSDefaultFlags,&code_path.value)!=errSecSuccess) return {};
  NSURL* bundle_url=(__bridge NSURL*)code_path.value;
  auto bundle=ParentCanonicalFile(bundle_url);
  if (!bundle || ![bundle_url.pathExtension isEqual:@"app"] || !p_dynamic->secured_info) return {};
  id executable=p_dynamic->secured_info[@"CFBundleExecutable"];
  if (![executable isKindOfClass:NSString.class] ||
      !ParentFixedTopology(*bundle,parent->executable,helper->executable,executable)) return {};
  std::vector<std::pair<std::string,bool>> files={{*bundle,true},{*bundle+"/Contents",true},
      {*bundle+"/Contents/MacOS",true},{parent->executable,false},{helper->executable,false},
      {*bundle+"/Contents/Info.plist",false},{*bundle+"/Contents/_CodeSignature",true},
      {*bundle+"/Contents/_CodeSignature/CodeResources",false}};
  std::vector<ParentImageFileStamp> pins;
  for (const auto& [path,directory] : files) {
    auto pin=ParentImageFileStamp::Read(path,directory);if (!pin) return {};pins.push_back(*pin);
  }
  NSURL* nested_url=[NSURL fileURLWithFileSystemRepresentation:helper->executable.c_str() isDirectory:NO relativeToURL:nil];
  if (SecStaticCodeCreateWithPath((__bridge CFURLRef)nested_url,kSecCSDefaultFlags,&nested_disk.value)!=errSecSuccess) return {};
  auto p_disk=ParentStrictStaticImage(parent_disk.value,requirement);
  auto h_disk=ParentStrictStaticImage(self_disk.value,nullptr);
  auto h_nested=ParentStrictStaticImage(nested_disk.value,nullptr);
  if (!p_disk || !h_disk || !h_nested || !p_disk->Same(*p_dynamic) ||
      !h_disk->Same(*h_dynamic) || !h_nested->Same(*h_dynamic)) return {};
  // Check actual running code again AFTER the strict original sealed bundle and
  // exact nested helper validation, not an on-disk source or code-ID label alone.
  auto p_after=ParentDynamicImage(parent->dynamic,requirement);
  auto h_after=ParentDynamicImage(actual_self.value,nullptr);
  if (!p_after || !h_after || !p_after->Same(*p_dynamic) || !h_after->Same(*h_dynamic)) return {};
  for (size_t i=0;i<files.size();++i) {
    auto pin=ParentImageFileStamp::Read(files[i].first,files[i].second);
    if (!pin || !pins[i].Same(*pin)) return {};
  }
  auto parent_after=Read(parent->pid,parent->audit), helper_after=Self();
  if (!Same(captured_parent,parent_after) || !Same(captured_helper,helper_after) ||
      !Same(parent,parent_after) || !Same(helper,helper_after)) return {};
  // FIRST actual pair can exist only AFTER the trusted compiled requirement,
  // complete strict nested/self validation and fresh final native checks above.
  if (observed_pair) *observed_pair=expected_pair ? expected_pair :
      std::shared_ptr<const OriginalParentImagePair>(new OriginalParentImagePair(policy,p_dynamic->unique,h_dynamic->unique));
  return parent_after;
}
