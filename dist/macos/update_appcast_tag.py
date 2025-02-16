"""
This script is used to update the appcast.xml file for tagged
Ghostty releases.

This expects the following files in the current directory:
    - sign_update.txt - contains the output from "sign_update" in the Sparkle
      framework for the current build.
    - appcast.xml - the existing appcast file.

And the following environment variables to be set:
    - GHOSTTY_VERSION - the version number (X.Y.Z format)
    - GHOSTTY_BUILD - the build number
    - GHOSTTY_COMMIT - the commit hash

The script will output a new appcast file called appcast_new.xml.
"""

import os
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

now = datetime.now(timezone.utc)
version = os.environ["GHOSTTY_VERSION"]
version_dash = version.replace('.', '-')
build = os.environ["GHOSTTY_BUILD"]
commit = os.environ["GHOSTTY_COMMIT"]
commit_long = os.environ["GHOSTTY_COMMIT_LONG"]
repo = "https://github.com/ghostty-org/ghostty"

# Read our sign_update output
with open("sign_update.txt", "r") as f:
    # format is a=b b=c etc. create a map of this. values may contain equal
    # signs, so we can't just split on equal signs.
    attrs = {}
    for pair in f.read().split(" "):
        key, value = pair.split("=", 1)
        value = value.strip()
        if value[0] == '"':
            value = value[1:-1]
        attrs[key] = value

# We need to register our namespaces before reading or writing any files.
namespaces = { "sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle" }
for prefix, uri in namespaces.items():
    ET.register_namespace(prefix, uri)

# Open our existing appcast and find the channel element. This is where
# we'll add our new item.
et = ET.parse('appcast.xml')
channel = et.find("channel")

# Remove any items with the same version. If we have multiple items with
# the same version, Sparkle will report invalid signatures if it picks
# the wrong one when updating.
for item in channel.findall("item"):
    sparkle_version = item.find("sparkle:version", namespaces)
    if sparkle_version is not None and sparkle_version.text == build:
        channel.remove(item)

    # We also remove any item that doesn't have a pubDate. This should
    # never happen but it prevents us from having to deal with it later.
    if item.find("pubDate") is None:
        channel.remove(item)

# Prune the oldest items if we have more than a limit.
prune_amount = 15
pubdate_format = "%a, %d %b %Y %H:%M:%S %z"
items = channel.findall("item")
items.sort(key=lambda item: datetime.strptime(item.find("pubDate").text, pubdate_format))
if len(items) > prune_amount:
    for item in items[:-prune_amount]:
        channel.remove(item)

# Create the item using some absolutely terrible XML manipulation.
item = ET.SubElement(channel, "item")
elem = ET.SubElement(item, "title")
elem.text = f"Build {build}"
elem = ET.SubElement(item, "pubDate")
elem.text = now.strftime(pubdate_format)
elem = ET.SubElement(item, "sparkle:version")
elem.text = build
elem = ET.SubElement(item, "sparkle:shortVersionString")
elem.text = f"{version}"
elem = ET.SubElement(item, "sparkle:minimumSystemVersion")
elem.text = "13.0.0"
elem = ET.SubElement(item, "sparkle:fullReleaseNotesLink")
elem.text = f"https://ghostty.org/docs/install/release-notes/{version_dash}"
elem = ET.SubElement(item, "description")
elem.text = f"""
<h1>Ghostty v{version}</h1>
<p>
This release was built from commit <code><a href="{repo}/commits/{commit_long}">{commit}</a></code>
on {now.strftime('%Y-%m-%d')}.
</p>
<p>
We don't currently generate release notes for auto-updates.
You can view the complete changelog and release notes
at <a href="https://ghostty.org/docs/install/release-notes/{version_dash}">ghostty.org/docs/install/release-notes/{version_dash}</a>.
</p>
"""
elem = ET.SubElement(item, "enclosure")
elem.set("url", f"https://release.files.ghostty.org/{version}/Ghostty.dmg")
elem.set("type", "application/octet-stream")
for key, value in attrs.items():
    elem.set(key, value)

# Output the new appcast.
et.write("appcast_new.xml", xml_declaration=True, encoding="utf-8")
