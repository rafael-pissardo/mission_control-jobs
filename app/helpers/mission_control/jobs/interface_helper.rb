module MissionControl::Jobs::InterfaceHelper
  def blank_status_notice(message)
    tag.div class: "mc-empty-state" do
      safe_join([
        tag.div("No results", class: "mc-empty-title"),
        tag.p(message, class: "mc-empty-message")
      ])
    end
  end

  def blank_status_emoji(status)
    ""
  end

  def modifier_for_status(status)
    {
      "failed"      => "mc-tag mc-tag--danger",
      "blocked"     => "mc-tag mc-tag--warning",
      "finished"    => "mc-tag mc-tag--success",
      "scheduled"   => "mc-tag mc-tag--info",
      "in_progress" => "mc-tag mc-tag--primary"
    }.fetch(status.to_s, "mc-tag mc-tag--neutral")
  end
end
