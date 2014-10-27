import re
import iso8601
from dateutil import tz
import time
import strict_rfc3339

def EST():
  return tz.gettz("America/New_York")

def in_est(dt):
  return dt.astimezone(EST())

def rfc3339(dt):
  t = time.mktime(dt.timetuple())
  return strict_rfc3339.timestamp_to_rfc3339_utcoffset(t)

def current_congress(year=None):
  if not year:
    year = current_legislative_year()
  return ((year + 1) / 2) - 894

def current_legislative_year(date=None):
  if not date:
    date = datetime.datetime.now()

  year = date.year

  if date.month == 1:
    if date.day == 1 or date.day == 2:
      return date.year - 1
    elif date.day == 3 and date.hour < 12:
      return date.year - 1
    else:
      return date.year
  else:
    return date.year

def parse_iso8601(timestamp):
  return iso8601.parse_date(timestamp).astimezone(tz.gettz('GMT'))

def extract_rolls(data, chamber, year):
  roll_ids = []

  roll_re = re.compile('Roll (?:no.|Call) (\d+)', flags=re.IGNORECASE)
  roll_matches = roll_re.findall(data)

  if roll_matches:
    for number in roll_matches:
      roll_id = "%s%s-%s" % (chamber[0], number, year)
      if roll_id not in roll_ids:
        roll_ids.append(roll_id)

  return roll_ids

def extract_bills(text, congress):
  bill_ids = []

  p = re.compile('((S\.|H\.)(\s?J\.|\s?R\.|\s?Con\.| ?)(\s?Res\.)*\s?\d+)', flags=re.IGNORECASE)
  bill_matches = p.findall(text)

  if bill_matches:
    for b in bill_matches:
      bill_text = "%s-%s" % (b[0].lower().replace(" ", '').replace('.', ''), congress)
      if bill_text not in bill_ids:
        bill_ids.append(bill_text)

  return bill_ids

# Only supports Chamber=House here in  congress / tasks / python_utils.py
# See also:  congress / tasks / floor_senate / floor_senate.rb
def extract_legislators(text, chamber, db):
  legislator_names = []
  bioguide_ids = []

  possibles = []

  name_re = re.compile('((M(rs|s|r)\.){1}\s((\s?[A-Z]{1}[A-Za-z-]+){0,2})(,\s?([A-Z]{1}[A-Za-z-]+))?((\sof\s([A-Z]{2}))|(\s?\(([A-Z]{2})\)))?)')

  name_matches = re.findall(name_re, text)
  if name_matches:
    for n in name_matches:
      raw_name = n[0]
      query = {"chamber": "house"}

      if n[1]:
        if n[1] == "Mr." : query["gender"] = 'M'
        else: query['gender'] = 'F'
      if n[3]:
        query["last_name"] = n[3]
      if n[6]:
        query["first_name"] = n[6]
      if n[9]:
        query["state"] = n[9]
      elif n[11]:
        query["state"] = n[11]

      possibles = db['legislators'].find(query)

    if possibles.count() > 0:
      if text not in legislator_names:
        legislator_names.append(raw_name)

    for p in possibles:
      if p['bioguide_id'] not in bioguide_ids:
        bioguide_ids.append(p['bioguide_id'])

  return (legislator_names, bioguide_ids)
