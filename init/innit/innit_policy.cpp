// innit_policy.cpp
// Innit policy engine: tinyxml2 load, rule evaluation, rejection logging.
//
// SPDX-License-Identifier: Apache-2.0

#include "innit_policy.h"

#include <chrono>
#include <ctime>
#include <fcntl.h>
#include <iomanip>
#include <optional>
#include <sstream>
#include <unistd.h>
#include <utility>

#include <android-base/logging.h>
#include <android-base/strings.h>
#include <tinyxml2.h>

namespace android::init::innit {
namespace {

using android::base::Error;
using android::base::Result;
using tinyxml2::XMLDocument;
using tinyxml2::XMLElement;
using tinyxml2::XML_SUCCESS;

std::string Attr(const XMLElement* e, const char* name) {
    const char* value = e->Attribute(name);
    return value ? std::string(value) : std::string();
}

Result<std::string> RequiredAttr(const XMLElement* e, const char* name) {
    std::string value = Attr(e, name);
    if (value.empty()) {
        return Error() << "Missing required attribute '" << name << "' on <" << e->Name() << ">";
    }
    return value;
}

Result<PolicyDecision> ParseDecisionStrict(const std::string& s, const char* attr) {
    if (s == "allow") return PolicyDecision::Allow;
    if (s == "deny") return PolicyDecision::Deny;
    return Error() << "Invalid " << attr << "='" << s << "', expected allow or deny";
}

Result<FailureAction> ParseFailureActionStrict(const std::string& s) {
    if (s == "reboot") return FailureAction::Reboot;
    if (s == "restart") return FailureAction::Restart;
    if (s == "log") return FailureAction::Log;
    if (s == "ignore") return FailureAction::Ignore;
    return Error() << "Invalid rebootOnFailure='" << s
                   << "', expected reboot, restart, log, or ignore";
}

Result<void> ParseOptionalDecision(const XMLElement* root, const char* attr,
                                   PolicyDecision* out) {
    std::string value = Attr(root, attr);
    if (value.empty()) return {};
    auto parsed = ParseDecisionStrict(value, attr);
    if (!parsed.ok()) return parsed.error();
    *out = *parsed;
    return {};
}

Result<void> ParseRuleList(const XMLElement* section, const char* attr_name,
                           std::vector<PolicyRule>* out) {
    for (const XMLElement* e = section->FirstChildElement(); e != nullptr;
         e = e->NextSiblingElement()) {
        std::string tag = e->Name();
        if (tag != "allow" && tag != "deny") {
            return Error() << "Unexpected <" << tag << "> inside <" << section->Name() << ">";
        }

        auto value = RequiredAttr(e, attr_name);
        if (!value.ok()) return value.error();

        out->push_back({tag == "allow" ? PolicyDecision::Allow : PolicyDecision::Deny, *value});
    }
    return {};
}

Result<void> ParseCommandPolicy(const XMLElement* section, InnitPolicy* policy) {
    for (const XMLElement* e = section->FirstChildElement(); e != nullptr;
         e = e->NextSiblingElement()) {
        std::string tag = e->Name();
        if (tag != "deny") {
            return Error() << "Unexpected <" << tag << "> inside <command-policy>";
        }

        auto verb = RequiredAttr(e, "verb");
        if (!verb.ok()) return verb.error();

        std::string arg = Attr(e, "arg");
        if (arg.empty()) {
            policy->AddDeniedCommand(*verb);
        } else {
            policy->AddDeniedCommandArg(*verb, arg);
        }
    }
    return {};
}

Result<void> ParseFailurePolicy(const XMLElement* section, InnitPolicy* policy) {
    for (const XMLElement* e = section->FirstChildElement(); e != nullptr;
         e = e->NextSiblingElement()) {
        std::string tag = e->Name();
        if (tag != "service") {
            return Error() << "Unexpected <" << tag << "> inside <failure-policy>";
        }

        auto name = RequiredAttr(e, "name");
        if (!name.ok()) return name.error();

        auto action_string = RequiredAttr(e, "rebootOnFailure");
        if (!action_string.ok()) return action_string.error();

        auto action = ParseFailureActionStrict(*action_string);
        if (!action.ok()) return action.error();

        policy->AddFailureRule(*name, *action);
    }
    return {};
}

Result<void> ParseLogging(const XMLElement* section, LoggingConfig* logging) {
    for (const XMLElement* e = section->FirstChildElement(); e != nullptr;
         e = e->NextSiblingElement()) {
        std::string tag = e->Name();
        auto value = RequiredAttr(e, "value");
        if (!value.ok()) return value.error();

        if (tag == "path") {
            logging->main_log = *value;
        } else if (tag == "rejectedRcLog") {
            logging->rejected_rc_log = *value;
        } else if (tag == "rejectedServiceLog") {
            logging->rejected_service_log = *value;
        } else if (tag == "rejectedExecLog") {
            logging->rejected_exec_log = *value;
        } else {
            return Error() << "Unexpected <" << tag << "> inside <logging>";
        }
    }
    return {};
}

bool IsAllowedRootAttr(const std::string& name) {
    return name == "version" || name == "mode" || name == "defaultRc" ||
           name == "defaultService" || name == "defaultExec" || name == "defaultEvent" ||
           name == "rebootOnFailure" || name == "selinuxMode" ||
           // accepted for compatibility with earlier policy drafts; defaultRc=deny is the actual gate.
           name == "unknownImport";
}

Result<void> ValidateRootAttributes(const XMLElement* root) {
    for (const tinyxml2::XMLAttribute* attr = root->FirstAttribute(); attr != nullptr;
         attr = attr->Next()) {
        if (!IsAllowedRootAttr(attr->Name())) {
            return Error() << "Unexpected root attribute '" << attr->Name() << "'";
        }
    }
    return {};
}

}  // namespace

// ── Glob matcher ──────────────────────────────────────────────────────────────
//
// Semantics:
//   '*'  — matches any run of characters that does not contain '/'
//   '**' — matches any run of characters including '/'
//
// Pattern and subject are compared verbatim and case-sensitively.

/*static*/ bool InnitPolicy::GlobMatch(const std::string& pattern,
                                        const std::string& subject) {
    std::function<bool(size_t, size_t)> match = [&](size_t p, size_t s) -> bool {
        while (p < pattern.size()) {
            if (pattern[p] == '*') {
                bool double_star = (p + 1 < pattern.size() && pattern[p + 1] == '*');
                size_t skip = double_star ? 2 : 1;
                for (size_t i = s; i <= subject.size(); ++i) {
                    if (!double_star && i > s && subject[i - 1] == '/') break;
                    if (match(p + skip, i)) return true;
                }
                return false;
            }
            if (s >= subject.size() || pattern[p] != subject[s]) return false;
            ++p;
            ++s;
        }
        return s == subject.size();
    };
    return match(0, 0);
}

// ── Mutators used by the strict XML loader ───────────────────────────────────

void InnitPolicy::AddRcRule(PolicyDecision decision, std::string pattern) {
    rc_rules_.push_back({decision, std::move(pattern)});
}

void InnitPolicy::AddEventRule(PolicyDecision decision, std::string pattern) {
    event_rules_.push_back({decision, std::move(pattern)});
}

void InnitPolicy::AddServiceRule(PolicyDecision decision, std::string pattern) {
    service_rules_.push_back({decision, std::move(pattern)});
}

void InnitPolicy::AddExecRule(PolicyDecision decision, std::string pattern) {
    exec_rules_.push_back({decision, std::move(pattern)});
}

void InnitPolicy::AddFailureRule(std::string name, FailureAction action) {
    ServiceFailureRule rule{std::move(name), action};
    if (rule.name_pattern == "*") {
        failure_rules_.push_back(std::move(rule));
        return;
    }

    auto it = failure_rules_.begin();
    while (it != failure_rules_.end() && it->name_pattern != "*") ++it;
    failure_rules_.insert(it, std::move(rule));
}

void InnitPolicy::AddDeniedCommand(std::string verb) {
    denied_commands_.push_back(std::move(verb));
}

void InnitPolicy::AddDeniedCommandArg(std::string verb, std::string arg) {
    denied_command_args_.emplace_back(std::move(verb), std::move(arg));
}

// ── Logging ───────────────────────────────────────────────────────────────────

static std::string Timestamp() {
    auto now = std::chrono::system_clock::now();
    std::time_t t = std::chrono::system_clock::to_time_t(now);
    std::ostringstream ss;
    ss << std::put_time(std::gmtime(&t), "%Y-%m-%dT%H:%M:%SZ");
    return ss.str();
}

void InnitPolicy::AppendToLog(const std::string& log_path,
                              const std::string& message) const {
    int fd = open(log_path.c_str(), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0) return;
    std::string line = Timestamp() + " " + message + "\n";
    write(fd, line.data(), line.size());
    close(fd);

    LOG(INFO) << "[Innit] " << message;
}

void InnitPolicy::LogRejectedRc(const std::string& path,
                                const std::string& reason) const {
    std::string msg = "reject rc " + path + " reason=" + reason;
    AppendToLog(logging_.rejected_rc_log, msg);
    AppendToLog(logging_.main_log, msg);
}

void InnitPolicy::LogRejectedService(const std::string& name,
                                     const std::string& reason) const {
    std::string msg = "reject service " + name + " reason=" + reason;
    AppendToLog(logging_.rejected_service_log, msg);
    AppendToLog(logging_.main_log, msg);
}

void InnitPolicy::LogRejectedExec(const std::string& path,
                                  const std::string& reason) const {
    std::string msg = "reject exec " + path + " reason=" + reason;
    AppendToLog(logging_.rejected_exec_log, msg);
    AppendToLog(logging_.main_log, msg);
}

void InnitPolicy::LogInfo(const std::string& message) const {
    AppendToLog(logging_.main_log, message);
}

// ── Rule evaluation ───────────────────────────────────────────────────────────

bool InnitPolicy::EvaluateRules(const std::vector<PolicyRule>& rules,
                                PolicyDecision default_decision,
                                const std::string& subject,
                                const std::string& reject_log_path) const {
    for (const auto& rule : rules) {
        if (GlobMatch(rule.pattern, subject)) {
            if (rule.decision == PolicyDecision::Deny) {
                std::string msg = "reject " + subject + " reason=explicit-deny pattern=" + rule.pattern;
                AppendToLog(reject_log_path, msg);
                AppendToLog(logging_.main_log, msg);
                return false;
            }
            return true;
        }
    }
    if (default_decision == PolicyDecision::Deny) {
        std::string msg = "reject " + subject + " reason=default-deny";
        AppendToLog(reject_log_path, msg);
        AppendToLog(logging_.main_log, msg);
        return false;
    }
    return true;
}

bool InnitPolicy::IsRcAllowed(const std::string& path) const {
    return EvaluateRules(rc_rules_, default_rc_, path, logging_.rejected_rc_log);
}

bool InnitPolicy::IsServiceAllowed(const std::string& name) const {
    return EvaluateRules(service_rules_, default_service_, name, logging_.rejected_service_log);
}

bool InnitPolicy::IsExecAllowed(const std::string& path) const {
    return EvaluateRules(exec_rules_, default_exec_, path, logging_.rejected_exec_log);
}

bool InnitPolicy::IsEventAllowed(const std::string& name) const {
    return EvaluateRules(event_rules_, default_event_, name, logging_.main_log);
}

bool InnitPolicy::IsCommandAllowed(const std::string& verb,
                                   const std::vector<std::string>& args) const {
    for (const auto& dc : denied_commands_) {
        if (verb == dc) {
            AppendToLog(logging_.main_log,
                        "reject command " + verb + " reason=command-denied");
            return false;
        }
    }

    if (!args.empty()) {
        for (const auto& [dverb, darg] : denied_command_args_) {
            if (verb == dverb && args[0] == darg) {
                AppendToLog(logging_.main_log,
                            "reject command " + verb + " " + args[0] +
                            " reason=command-arg-denied");
                return false;
            }
        }
    }
    return true;
}

// ── Failure action lookup ─────────────────────────────────────────────────────

FailureAction InnitPolicy::GetFailureAction(const std::string& service_name) const {
    for (const auto& rule : failure_rules_) {
        if (rule.name_pattern == service_name) return rule.action;
    }
    for (const auto& rule : failure_rules_) {
        if (rule.name_pattern == "*") return rule.action;
    }
    return FailureAction::Reboot;
}

// ── XML loading via dynamic libtinyxml2 ───────────────────────────────────────

/*static*/ android::base::Result<InnitPolicy>
InnitPolicy::LoadFromFile(const std::string& path) {
    InnitPolicy policy;

    XMLDocument doc;
    auto err = doc.LoadFile(path.c_str());
    if (err != XML_SUCCESS) {
        return Error() << "Cannot parse Innit policy " << path << ": "
                       << doc.ErrorStr() << " at line " << doc.ErrorLineNum();
    }

    const XMLElement* root = doc.RootElement();
    if (root == nullptr || std::string(root->Name()) != "innit") {
        return Error() << "Innit policy root must be <innit>";
    }

    auto root_attr = ValidateRootAttributes(root);
    if (!root_attr.ok()) return root_attr.error();

    policy.mode_ = Attr(root, "mode");

    if (auto r = ParseOptionalDecision(root, "defaultRc", &policy.default_rc_); !r.ok()) {
        return r.error();
    }
    if (auto r = ParseOptionalDecision(root, "defaultService", &policy.default_service_); !r.ok()) {
        return r.error();
    }
    if (auto r = ParseOptionalDecision(root, "defaultExec", &policy.default_exec_); !r.ok()) {
        return r.error();
    }
    if (auto r = ParseOptionalDecision(root, "defaultEvent", &policy.default_event_); !r.ok()) {
        return r.error();
    }

    std::string rof = Attr(root, "rebootOnFailure");
    if (!rof.empty()) {
        auto action = ParseFailureActionStrict(rof);
        if (!action.ok()) return action.error();
        policy.AddFailureRule("*", *action);
    }

    std::string se_mode = Attr(root, "selinuxMode");
    if (!se_mode.empty()) {
        if (se_mode == "permissive") {
            policy.selinux_mode_ = SelinuxMode::Permissive;
        } else if (se_mode == "default") {
            policy.selinux_mode_ = SelinuxMode::Default;
        } else {
            return Error() << "Invalid selinuxMode='" << se_mode
                           << "', expected default or permissive";
        }
    }

    for (const XMLElement* section = root->FirstChildElement(); section != nullptr;
         section = section->NextSiblingElement()) {
        std::string tag = section->Name();

        if (tag == "identity") {
            continue;
        } else if (tag == "rc-policy") {
            auto r = ParseRuleList(section, "path", &policy.rc_rules_);
            if (!r.ok()) return r.error();
        } else if (tag == "event-policy") {
            auto r = ParseRuleList(section, "name", &policy.event_rules_);
            if (!r.ok()) return r.error();
        } else if (tag == "service-policy") {
            auto r = ParseRuleList(section, "name", &policy.service_rules_);
            if (!r.ok()) return r.error();
        } else if (tag == "exec-policy") {
            auto r = ParseRuleList(section, "path", &policy.exec_rules_);
            if (!r.ok()) return r.error();
        } else if (tag == "command-policy") {
            auto r = ParseCommandPolicy(section, &policy);
            if (!r.ok()) return r.error();
        } else if (tag == "failure-policy") {
            auto r = ParseFailurePolicy(section, &policy);
            if (!r.ok()) return r.error();
        } else if (tag == "logging") {
            auto r = ParseLogging(section, &policy.logging_);
            if (!r.ok()) return r.error();
        } else {
            return Error() << "Unexpected top-level policy section <" << tag << ">";
        }
    }

    policy.loaded_ = true;
    return policy;
}

// ── Global singleton ──────────────────────────────────────────────────────────

static std::optional<InnitPolicy> g_policy;

void InitialiseInnitPolicy(const std::string& policy_path) {
    auto result = InnitPolicy::LoadFromFile(policy_path);
    if (!result.ok()) {
        LOG(ERROR) << "[Innit] Failed to load policy from " << policy_path
                   << ": " << result.error();
        return;
    }
    g_policy = std::move(*result);
    g_policy->LogInfo("Innit policy loaded. mode=" + g_policy->GetMode());
    LOG(INFO) << "[Innit] Policy active. mode=" << g_policy->GetMode();
}

InnitPolicy& GetInnitPolicy() {
    CHECK(g_policy.has_value()) << "GetInnitPolicy() called before InitialiseInnitPolicy()";
    return *g_policy;
}

bool InnitPolicyIsActive() {
    return g_policy.has_value() && g_policy->IsLoaded();
}

}  // namespace android::init::innit
