#!/usr/bin/env python3
"""Patch frontend auth-form.tsx for auto-login with bootstrap credentials.

1. Pre-fill password from __UNSLOTH_BOOTSTRAP__ in login mode (not just
   change-password mode).
2. Auto-submit the login form when bootstrap credentials are available,
   skipping the login page entirely.
"""

AUTH_FORM = "/opt/venv/lib/python3.12/site-packages/studio/frontend/src/features/auth/components/auth-form.tsx"

with open(AUTH_FORM) as f:
    content = f.read()

# 1. Allow bootstrap password to pre-fill in login mode too
old = "if (bootstrap && !isLoginMode && !password) {"
new = "if (bootstrap && !password) {"
if old not in content:
    raise SystemExit(f"ERROR: auth-form.tsx marker 1 not found")
content = content.replace(old, new)
print("Patched auth-form.tsx: bootstrap pre-fills password in all modes")

# 2. Insert hasPassword + auto-login useEffect after currentPassword line.
#    Must go after currentPassword so hasPassword is declared before the
#    useEffect that references it.
old = (
    '  const currentPassword = password || window.__UNSLOTH_BOOTSTRAP__?.password || "";\n'
    "  const invalidChangePasswordForm ="
)
new = (
    "  const hasPassword = password.length > 0;\n"
    '  const currentPassword = password || window.__UNSLOTH_BOOTSTRAP__?.password || "";\n'
    "\n"
    "  // Auto-login when bootstrap credentials are available (login mode only).\n"
    "  // The bootstrap password is pre-filled above; as soon as auth status\n"
    "  // confirms no password change is required, submit the form automatically.\n"
    "  const [autoLoginFired, setAutoLoginFired] = useState(false);\n"
    "  useEffect(() => {\n"
    "    if (\n"
    "      autoLoginFired ||\n"
    "      !isLoginMode ||\n"
    "      statusLoading ||\n"
    "      requiresPasswordChange ||\n"
    "      initialized === null ||\n"
    "      !hasPassword\n"
    "    ) return;\n"
    "    const bootstrap = window.__UNSLOTH_BOOTSTRAP__;\n"
    "    if (!bootstrap) return;\n"
    "    // Defer to let the form finish mounting and state settle\n"
    "    const timer = setTimeout(() => {\n"
    "      const form = document.querySelector(\"form\");\n"
    "      if (form) {\n"
    "        setAutoLoginFired(true);\n"
    "        form.requestSubmit();\n"
    "      }\n"
    "    }, 300);\n"
    "    return () => clearTimeout(timer);\n"
    "  }, [isLoginMode, statusLoading, requiresPasswordChange, initialized, hasPassword]);\n"
    "\n"
    "  const invalidChangePasswordForm ="
)
if old not in content:
    raise SystemExit(f"ERROR: auth-form.tsx marker 2 not found")
content = content.replace(old, new)
print("Patched auth-form.tsx: added hasPassword + auto-submit login")

with open(AUTH_FORM, "w") as f:
    f.write(content)
