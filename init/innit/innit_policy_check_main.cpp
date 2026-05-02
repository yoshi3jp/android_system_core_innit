// innit_policy_check_main.cpp
// Innit host-side policy validator.
//
// Usage:
//   innit_policy_check --policy innit.xml [--rc path/to/file.rc ...]
//                      [--service name] [--exec path] [--event name]
//                      [--command verb [arg]]
//
// Exit codes:
//   0  all subjects are allowed
//   1  one or more subjects were denied
//   2  policy file could not be loaded
//
// SPDX-License-Identifier: Apache-2.0

#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

#include "innit/innit_policy.h"

using android::init::innit::InnitPolicy;
using android::init::innit::FailureAction;

static void Usage(const char* argv0) {
    std::cerr << "Usage: " << argv0 << "\n"
              << "  --policy <innit.xml>    (required)\n"
              << "  --rc     <path>         Check rc file path against policy\n"
              << "  --service <name>        Check service name\n"
              << "  --exec   <path>         Check executable path\n"
              << "  --event  <name>         Check event trigger name\n"
              << "  --command <verb> [arg]  Check command (and optional first arg)\n"
              << "  --failure <service>     Print failure action for service\n"
              << "  --verbose               Print allow decisions as well as denials\n";
}

int main(int argc, char** argv) {
    std::string policy_path;
    bool        verbose = false;
    int         exit_code = 0;

    struct Check { std::string type; std::string a; std::string b; };
    std::vector<Check> checks;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--policy") {
            if (++i >= argc) { Usage(argv[0]); return 2; }
            policy_path = argv[i];
        } else if (arg == "--verbose") {
            verbose = true;
        } else if (arg == "--rc" || arg == "--service" ||
                   arg == "--exec" || arg == "--event" || arg == "--failure") {
            if (++i >= argc) { Usage(argv[0]); return 2; }
            checks.push_back({arg.substr(2), argv[i], {}});
        } else if (arg == "--command") {
            if (++i >= argc) { Usage(argv[0]); return 2; }
            std::string verb = argv[i];
            std::string opt_arg;
            if (i + 1 < argc && argv[i+1][0] != '-') opt_arg = argv[++i];
            checks.push_back({"command", verb, opt_arg});
        } else {
            std::cerr << "Unknown argument: " << arg << "\n";
            Usage(argv[0]);
            return 2;
        }
    }

    if (policy_path.empty()) {
        std::cerr << "Error: --policy is required.\n";
        Usage(argv[0]);
        return 2;
    }

    auto result = InnitPolicy::LoadFromFile(policy_path);
    if (!result.ok()) {
        std::cerr << "ERROR: " << result.error() << "\n";
        return 2;
    }
    InnitPolicy& policy = *result;
    std::cout << "Policy loaded. mode=" << policy.GetMode() << "\n";

    for (const auto& chk : checks) {
        bool allowed = false;

        if (chk.type == "rc") {
            allowed = policy.IsRcAllowed(chk.a);
            std::cout << "[rc]      " << chk.a
                      << " => " << (allowed ? "ALLOW" : "DENY") << "\n";
        } else if (chk.type == "service") {
            allowed = policy.IsServiceAllowed(chk.a);
            std::cout << "[service] " << chk.a
                      << " => " << (allowed ? "ALLOW" : "DENY") << "\n";
        } else if (chk.type == "exec") {
            allowed = policy.IsExecAllowed(chk.a);
            std::cout << "[exec]    " << chk.a
                      << " => " << (allowed ? "ALLOW" : "DENY") << "\n";
        } else if (chk.type == "event") {
            allowed = policy.IsEventAllowed(chk.a);
            std::cout << "[event]   " << chk.a
                      << " => " << (allowed ? "ALLOW" : "DENY") << "\n";
        } else if (chk.type == "command") {
            std::vector<std::string> args;
            if (!chk.b.empty()) args.push_back(chk.b);
            allowed = policy.IsCommandAllowed(chk.a, args);
            std::string label = chk.a + (chk.b.empty() ? "" : " " + chk.b);
            std::cout << "[command] " << label
                      << " => " << (allowed ? "ALLOW" : "DENY") << "\n";
        } else if (chk.type == "failure") {
            auto action = policy.GetFailureAction(chk.a);
            std::string action_str;
            switch (action) {
                case FailureAction::Log:     action_str = "log";     break;
                case FailureAction::Restart: action_str = "restart"; break;
                case FailureAction::Ignore:  action_str = "ignore";  break;
                case FailureAction::Reboot:  action_str = "reboot";  break;
            }
            std::cout << "[failure] " << chk.a << " => " << action_str << "\n";
            allowed = true;  // failure queries do not affect exit code
        }

        if (!allowed) exit_code = 1;
    }

    return exit_code;
}
