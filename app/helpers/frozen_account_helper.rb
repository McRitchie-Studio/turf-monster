# OPSEC-048 in the views: the banner every page shows a frozen account, and the
# reason a disabled call to action gives. The server refuses the write either
# way (FrozenAccountGuard); this only stops a page offering what it would refuse.
module FrozenAccountHelper
  def account_frozen?
    logged_in? && current_user&.frozen? ? true : false
  end
end
