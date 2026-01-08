# Root bashrc to ensure interactive shells show the welcome message.
if [ -r /etc/profile.d/pgbackup-welcome.sh ]; then
  . /etc/profile.d/pgbackup-welcome.sh
fi
