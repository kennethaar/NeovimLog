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

    for url in urls:
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
            with urllib.request.urlopen(req, timeout=10) as response:
                ical_string = response.read()
            
            calendar = icalendar.Calendar.from_ical(ical_string)
            # Håndterer avanserte repeterende hendelser og tidssoner
            events = recurring_ical_events.of(calendar).at(today)
            
            for event in events:
                raw_uid = str(event.get("UID", ""))
                # Lager en kort 3-tegns ID i stedet for en massiv streng
                uid = hashlib.md5(raw_uid.encode('utf-8')).hexdigest()[:3] if raw_uid else "000"
                
                summary = str(event.get("SUMMARY", "(Uten tittel)"))
                start = event.get("DTSTART").dt
                end = event.get("DTEND").dt if event.get("DTEND") else None
                
                # Sjekk om det er en heldagshendelse (datetime.date i stedet for datetime.datetime)
                is_allday = not isinstance(start, datetime)
                
                if is_allday:
                    time_str = "Heldags"
                else:
                    # Konverter til lokal tidssone
                    local_tz = datetime.now(pytz.utc).astimezone().tzinfo
                    start_local = start.astimezone(local_tz)
                    if end and isinstance(end, datetime):
                        end_local = end.astimezone(local_tz)
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
            # Feiler stille i Python, Lua-skriptet vil fange opp om det mangler data
            pass

    # Sorter: Heldags først, deretter på tid
    events_out.sort(key=lambda x: (not x["is_allday"], x["time_str"]))
    print(json.dumps(events_out))

if __name__ == "__main__":
    if len(sys.argv) > 1:
        urls = json.loads(sys.argv[1])
        fetch_and_parse(urls)