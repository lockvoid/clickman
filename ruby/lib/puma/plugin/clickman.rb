require 'puma/plugin'
require 'click_man'

Puma::Plugin.create do
  def start(launcher)
    supervisor = ClickMan::InlineSupervisor.new(launcher: launcher)
    owner_pid = Process.pid
    at_exit { supervisor.stop if Process.pid == owner_pid }

    launcher.events.after_booted { supervisor.start }
    launcher.events.before_restart { supervisor.stop }
  end
end
