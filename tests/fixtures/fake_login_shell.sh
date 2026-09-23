#!/usr/bin/env bash
# Test stand-in for the user's login shell. pfr invokes it as
#   fake_login_shell.sh -lic CMD   |   -ic CMD   |   -il -c CMD
# and it runs CMD (always the last argument) in an interactive bash whose only
# startup file is $PFR_TEST_SHELL_RC, so alias/function probes do not depend on
# the developer's dotfiles.
cmd="${!#}"
exec bash --noprofile --rcfile "${PFR_TEST_SHELL_RC:-/dev/null}" -i -c "$cmd"
