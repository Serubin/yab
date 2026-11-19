// A site's notification on its way to Yab, and the person's answer on its way
// back to Chromium. site_notice_center.mm stands in for macOS's center in
// Chrome's own notification service, so a page, a service worker, a tag, a
// close and a click are Chromium's as ever: only the banner is Yab's.
static constexpr NSUInteger kNoticeLimit = 8 * 1024 * 1024;
static void SendNotice(NSDictionary* change) {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSString* op = S(change, @"op");
    Event([@"notification." stringByAppendingString:op], nullptr, change);
  });
}
// The Alerts helper's notification service, the only child that sends here:
// one change a Mach message, under a name checked in for this process alone,
// as Chromium checks in MachPortRendezvousServer.<pid>. A message counts only
// from a child of this process running the Alerts helper.
static NSString* noticesService = nil;
static bool FromAlertsHelper(const audit_token_t& token) {
  pid_t pid = audit_token_to_pid(token);
  proc_bsdinfo info{};
  if (pid <= 0 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) ||
      static_cast<pid_t>(info.pbi_ppid) != getpid()) return false;
  char path[PROC_PIDPATHINFO_MAXSIZE]{};
  if (proc_pidpath(pid, path, sizeof(path)) <= 0) return false;
  return [@(path) hasSuffix:@"/Contents/Frameworks/YabCore Helper (Alerts).app/Contents/MacOS/YabCore Helper (Alerts)"];
}
static void ReadHelperNotice(mach_port_t port) {
  struct {
    yc::notices::NoticeMessage message;
    mach_msg_audit_trailer_t trailer;
  } got{};
  kern_return_t read = mach_msg(&got.message.header,
      MACH_RCV_MSG | MACH_RCV_TIMEOUT | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) | MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT),
      0, sizeof(got), port, 0, MACH_PORT_NULL);
  if (read != KERN_SUCCESS) return;
  bool complex = got.message.header.msgh_bits & MACH_MSGH_BITS_COMPLEX;
  bool shaped = complex && got.message.header.msgh_id == yc::notices::kNoticeMessage &&
                got.message.header.msgh_size == sizeof(got.message) && got.message.body.msgh_descriptor_count == 1 &&
                got.message.json.type == MACH_MSG_OOL_DESCRIPTOR;
  NSData* data = nil;
  if (shaped && got.message.json.size <= kNoticeLimit && FromAlertsHelper(got.trailer.msgh_audit))
    data = [NSData dataWithBytes:got.message.json.address length:got.message.json.size];
  mach_msg_destroy(&got.message.header);
  NSDictionary* change = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if (![change isKindOfClass:NSDictionary.class]) return;
  NSString* op = S(change, @"op");
  if ([op isEqual:@"show"]) yc::notices::AdoptFromHelper(change);
  if ([op isEqual:@"close"]) yc::notices::ForgetFromHelper(change);
  SendNotice(change);
}
static void ListenForHelperNotices() {
  NSString* base = NSBundle.mainBundle.bundleIdentifier ?: @"net.serubin.pane";
  NSString* name = [NSString stringWithFormat:@"%@.YabNotices.%d", base, getpid()];
  mach_port_t port = MACH_PORT_NULL;
  if (name.length >= sizeof(name_t) ||
      bootstrap_check_in(bootstrap_port, const_cast<char*>(name.UTF8String), &port) != KERN_SUCCESS) {
    fprintf(stderr, "YabCore: no notification service name for the Alerts helper\n");
    return;
  }
  noticesService = name;
  dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, port, 0, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
  dispatch_source_set_event_handler(source, ^{ ReadHelperNotice(port); });
  dispatch_resume(source);
  static dispatch_source_t keep;
  keep = source;
}
static void StartSiteNotices() {
  ListenForHelperNotices();
  if (!yc::notices::Install(SendNotice, true)) fprintf(stderr, "YabCore: no notification center to stand in for\n");
}
static bool IsNoticeService(CefRefPtr<CefCommandLine> command) {
  return command->GetSwitchValue("type").ToString() == "utility" &&
         command->GetSwitchValue("utility-sub-type").ToString() == "mac_notifications.mojom.MacNotificationProvider";
}
static void SiteNoticesToChild(CefRefPtr<CefCommandLine> command) {
  if (noticesService && IsNoticeService(command)) command->AppendSwitchWithValue("yab-notices", Key(noticesService));
}
static bool SiteNoticeRequest(NSString* method, NSDictionary* p, NSString* request) {
  if (![method isEqual:@"notification.answer"]) return false;
  NSDictionary* info = @{@"notificationId": S(p, @"id"), @"notificationProfileId": S(p, @"profile"),
                         @"notificationIncognito": @([p[@"incognito"] boolValue]), @"notificationOrigin": S(p, @"origin"),
                         @"notificationType": @([p[@"type"] intValue]), @"notificationUserDataDir": S(p, @"directory"),
                         @"key": S(p, @"key")};
  if (![S(p, @"action") isEqual:@"close"]) noticeClickedAt = Now();
  bool answered = yc::notices::Activate(S(p, @"action"), [p[@"index"] integerValue], info);
  Reply(request, @{@"answered": @(answered)});
  return true;
}
