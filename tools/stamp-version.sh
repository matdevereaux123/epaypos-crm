#!/bin/sh
# Stamp the deployed build's identity into app/index.html.
#
# The app is one static file with no build step, so a version constant kept
# by hand goes stale the first time somebody forgets. This replaces the
# __APP_VERSION__ placeholder at deploy time with the date and the commit
# Netlify is actually building, which means the number on the login screen
# always names the code that is running.
#
# Netlify runs this in a throwaway checkout, so editing the file here does
# not touch the repository.
#
# It must never fail a deploy: a missing version is a cosmetic problem, a
# failed build is an outage. Hence the exit 0 at the end.

SHA=$(echo "${COMMIT_REF:-local}" | cut -c1-7)
STAMP="$(date -u +%Y.%m.%d).${SHA}"

if grep -q "__APP_VERSION__" app/index.html 2>/dev/null; then
  sed -i.bak "s/__APP_VERSION__/${STAMP}/g" app/index.html && rm -f app/index.html.bak
  echo "Stamped version ${STAMP}"
else
  echo "No __APP_VERSION__ placeholder found — leaving app/index.html alone"
fi

exit 0
