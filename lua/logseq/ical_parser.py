import sys
import json
import urllib.request
from datetime import datetime
import pytz
import icalendar
import recurring_ical_events
import hashlib

def fetch_and_parse(urls):
    today = datetime.now().date()
    events_out = []

    # Explicitly enforce Central European Timezone (handles both CET and CEST)
    local_tz = pytz.timezone('Europe/Oslo')

    for url in urls:
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
            with urllib.request.urlopen(req, timeout=10) as response:
                ical_string = response.read()

            calendar = icalendar.Calendar.from_ical(ical_string)
            events = recurring_ical_events.of(calendar).at(today)

            for event in events:
                raw_uid = str(event.get("UID", ""))
                
                # 4 characters provides 65,536 combinations, perfectly safe for ~10 events/day
                uid = hashlib.md5(raw_uid.encode('utf-8')).hexdigest()[:4] if raw_uid else "0000"

                summary = str(event.get("SUMMARY", "(Uten tittel)"))
                
                start_prop = event.get("DTSTART")
                if not start_prop:
                    continue  # Skip events with no start time
                    
                start = start_prop.dt
                end_prop = event.get("DTEND")
                end_dt = end_prop.dt if end_prop else None

                # Sjekk om det er en heldagshendelse
                is_allday = not isinstance(start, datetime)

                if is_allday:
                    time_str = "Heldags"
                else:
                    # Sikre at start-tidspunktet har en tidssone før vi konverterer
                    if start.tzinfo is None:
                        start = pytz.utc.localize(start)
                    start_local = start.astimezone(local_tz)

                    if end_dt and isinstance(end_dt, datetime):
                        if end_dt.tzinfo is None:
                            end_dt = pytz.utc.localize(end_dt)
                        end_local = end_dt.astimezone(local_tz)
                        time_str = f"{start_local.strftime('%H:%M')}-{end_local.strftime('%H:%M')}"
                    else:
                        time_str = start_local.strftime('%H:%M')

                events_out.append({
                    "uid": uid,
                    "summary": summary,
                    "time_str": time_str,
                    "is_allday": is_allday
                })

        except Exception as e:
            # Sender feil til Neovim for visning i stedet for å feile stille
            print(f"Error fetching/parsing {url}: {str(e)}", file=sys.stderr)

    # Sorter: Heldags først, deretter på tid
    events_out.sort(key=lambda x: (not x["is_allday"], x["time_str"]))
    
    print(json.dumps(events_out))


if __name__ == "__main__":
    if len(sys.argv) > 1:
        try:
            urls = json.loads(sys.argv[1])
            fetch_and_parse(urls)
        except json.JSONDecodeError:
            print("Invalid JSON provided to Python script.", file=sys.stderr)
            sys.exit(1)

