import requests

KNESSET_FACTION_URL = (
    'https://knesset.gov.il/Odata/ParliamentInfo.svc/KNS_Faction'
    '?$format=json&$filter=IsCurrent%20eq%20true'
)


def parse_current_factions(odata_json):
    rows = odata_json.get('value', [])
    if not rows:
        return []

    max_knesset_num = max(row['KnessetNum'] for row in rows)
    return [
        {'knesset_faction_id': str(row['FactionID']), 'name': row['Name'].strip()}
        for row in rows
        if row['KnessetNum'] == max_knesset_num
    ]


def fetch_current_factions():
    resp = requests.get(KNESSET_FACTION_URL, timeout=15)
    resp.raise_for_status()
    return parse_current_factions(resp.json())
