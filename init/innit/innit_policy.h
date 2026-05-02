// innit_policy.h
// Innit: DS-GSI boot-policy gatekeeper
// Policy engine interface — loaded once at SecondStageInit, consulted throughout.
//
// Design contract:
//   - Unknown subject => deny (allowlist semantics)
//   - Rules evaluated first-match-wins, in declaration order
//   - All rejections are logged to /ds/log/
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <string>
#include <vector>
#include <functional>
#include <utility>

#include <android-base/result.h>

namespace android::init::innit {

// ── Enumerations ──────────────────────────────────────────────────────────────

enum class PolicyDecision {
    Allow,
    Deny,
};

// Outcome when a supervised service exits unexpectedly
enum class FailureAction {
    Reboot,   // Android default: propagate reboot_on_failure
    Restart,  // Restart the service
    Log,      // Log only; do not reboot, do not restart
    Ignore,   // Silent; no action taken
};

enum class SelinuxMode {
    Default,     // Load and enforce the policy present in the image
    Permissive,  // Force permissive regardless of image policy
};

// ── Rule structures ───────────────────────────────────────────────────────────

struct PolicyRule {
    PolicyDecision decision;
    std::string    pattern;  // Glob: '*' single-segment, '**' recursive
};

// Failure rule for a specific service name or '*' wildcard
struct ServiceFailureRule {
    std::string   name_pattern;
    FailureAction action;
};

struct LoggingConfig {
    std::string main_log            = "/ds/log/innit.log";
    std::string rejected_rc_log     = "/ds/log/innit-rejected-rc.log";
    std::string rejected_service_log= "/ds/log/innit-rejected-services.log";
    std::string rejected_exec_log   = "/ds/log/innit-rejected-exec.log";
};

// ── InnitPolicy ───────────────────────────────────────────────────────────────

class InnitPolicy {
  public:
    // Load and parse /system/etc/init/hw/innit.xml (or a given path).
    // Returns an error if the file is missing or malformed.
    static android::base::Result<InnitPolicy> LoadFromFile(const std::string& path);

    // ── Gate functions ──────────────────────────────────────────────────────
    // Each returns true (allowed) or false (denied).
    // All denials are written to the appropriate rejection log.

    bool IsRcAllowed(const std::string& path) const;
    bool IsServiceAllowed(const std::string& name) const;
    bool IsExecAllowed(const std::string& path) const;
    bool IsEventAllowed(const std::string& name) const;

    // Checks a single init command keyword against the command gate.
    // args[0] is the command verb (e.g. "start", "trigger", "class_start").
    // args[1..] are the command arguments.
    bool IsCommandAllowed(const std::string& verb,
                          const std::vector<std::string>& args) const;

    // ── Failure policy ──────────────────────────────────────────────────────
    // Returns the most specific FailureAction for a service name.
    // Falls back to the wildcard rule, then to FailureAction::Reboot if
    // no rule matches (preserving stock Android behaviour by default).
    FailureAction GetFailureAction(const std::string& service_name) const;

    // ── Accessors ───────────────────────────────────────────────────────────
    bool         IsLoaded()       const { return loaded_; }
    const std::string& GetMode()  const { return mode_; }
    SelinuxMode  GetSelinuxMode() const { return selinux_mode_; }

    // ── Logging helpers ─────────────────────────────────────────────────────
    void LogRejectedRc     (const std::string& path,
                            const std::string& reason) const;
    void LogRejectedService(const std::string& name,
                            const std::string& reason) const;
    void LogRejectedExec   (const std::string& path,
                            const std::string& reason) const;
    void LogInfo           (const std::string& message) const;

    // Internal mutators used by the tinyxml2 policy loader.
    void AddRcRule(PolicyDecision decision, std::string pattern);
    void AddEventRule(PolicyDecision decision, std::string pattern);
    void AddServiceRule(PolicyDecision decision, std::string pattern);
    void AddExecRule(PolicyDecision decision, std::string pattern);
    void AddFailureRule(std::string name, FailureAction action);
    void AddDeniedCommand(std::string verb);
    void AddDeniedCommandArg(std::string verb, std::string arg);

  private:
    // Evaluate an ordered rule list against a subject string.
    // Returns the decision of the first matching rule, or default_decision
    // if no rule matches.
    bool EvaluateRules(const std::vector<PolicyRule>& rules,
                       PolicyDecision                 default_decision,
                       const std::string&             subject,
                       const std::string&             reject_log_path) const;

    // Glob matching: '*' matches any sequence of characters within a single
    // path segment; '**' matches across segment boundaries.
    static bool GlobMatch(const std::string& pattern,
                          const std::string& subject);

    void AppendToLog(const std::string& log_path,
                     const std::string& message) const;

    // ── Policy state ────────────────────────────────────────────────────────
    bool          loaded_       = false;
    std::string   mode_;
    SelinuxMode   selinux_mode_ = SelinuxMode::Default;

    PolicyDecision default_rc_      = PolicyDecision::Deny;
    PolicyDecision default_service_ = PolicyDecision::Deny;
    PolicyDecision default_exec_    = PolicyDecision::Deny;
    PolicyDecision default_event_   = PolicyDecision::Deny;

    std::vector<PolicyRule>        rc_rules_;
    std::vector<PolicyRule>        event_rules_;
    std::vector<PolicyRule>        service_rules_;
    std::vector<PolicyRule>        exec_rules_;
    std::vector<ServiceFailureRule> failure_rules_;

    // Denied command verbs: if the verb appears here, the entire command line
    // is rejected regardless of arguments.
    std::vector<std::string> denied_commands_;

    // Denied command+argument pairs, e.g. {"trigger", "early-fs"}.
    // Checked after per-verb denial.
    std::vector<std::pair<std::string, std::string>> denied_command_args_;

    LoggingConfig logging_;
};

// ── Global singleton ──────────────────────────────────────────────────────────
//
// Initialised once in SecondStageInit() via InitialiseInnitPolicy().
// All other callers use GetInnitPolicy().

void            InitialiseInnitPolicy(const std::string& policy_path =
                                      "/system/etc/init/hw/innit.xml");
InnitPolicy&    GetInnitPolicy();
bool            InnitPolicyIsActive();

}  // namespace android::init::innit
