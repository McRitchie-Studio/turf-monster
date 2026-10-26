# Be sure to restart your server when you modify this file.
#
# Turf serves its assets through Propshaft (moved off Sprockets by task
# turf-moves-to-propshaft). Every file under app/assets/*, app/javascript and
# vendor/javascript, and every engine's app/assets/*, is an asset on the load
# path: there is no precompile list and no manifest.js. tailwindcss-rails keeps
# app/assets/tailwind (the Tailwind SOURCE) off the path; the build lands in
# app/assets/builds/tailwind.css. docs/RUNBOOK.md, "Asset pipeline (Propshaft)".

# Version of your assets, change this if you want to expire all your assets.
# Propshaft folds it into every digest.
Rails.application.config.assets.version = "1.0"
