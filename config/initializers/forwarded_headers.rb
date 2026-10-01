# WHICH PROXY HEADER NAMES THE CLIENT. One answer, for every reader of the
# client address: rack-attack's `req.ip` and Rails' `request.remote_ip`.
#
# Rack 3 reads the standard `Forwarded` header BEFORE `X-Forwarded-For`
# (Rack::Request.forwarded_priority defaults to [:forwarded, :x_forwarded]),
# and Rails' RemoteIp middleware takes its list from the same method
# (ActionDispatch::Request#forwarded_for is Rack's). The Heroku router does not
# set `Forwarded` and does not strip it, so until this line a caller could
# write their own address:
#
#     Forwarded: for=160.79.104.5
#
# and every per-IP throttle counted them as that address, a fresh one on each
# request if they liked; geo detection, which reads remote_ip, saw it too.
#
# The header Heroku DOES control is X-Forwarded-For: "If the Heroku router
# receives a request with the X-Forwarded-For header already present, the
# originating IP detected by the router is appended to the right-side of the
# list" (https://devcenter.heroku.com/articles/http-routing, read 2026-10-01).
# Rack and Rails both walk that list from the right and stop at the first
# address that is not a private one, so a value the client put on the left is
# never reached. With `Forwarded` out of the list, the address every reader
# gets is the one the router wrote.
#
# It also stops `Forwarded: host=…;proto=…` from setting request.host and
# request.scheme, which read the same priority list. X-Forwarded-Proto and
# X-Forwarded-Port, which the router sets, are unaffected.
#
# A request with no `Forwarded` header, which is every browser and every
# request the router forwards unmodified, is read exactly as before.
#
# If a proxy that DOES speak `Forwarded` is ever put in front of the router,
# revisit this. test/integration/client_ip_spoof_test.rb holds the property.
Rack::Request.forwarded_priority = [:x_forwarded]
