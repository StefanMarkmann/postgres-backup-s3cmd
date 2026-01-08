# System-wide bashrc.
# Ensure login-style profile scripts run for interactive, non-login shells.
if [ -r /etc/profile ]; then
  . /etc/profile
fi
