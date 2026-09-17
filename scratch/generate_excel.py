import os
import json
import csv
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

safe_zones = [
    # --- Police Stations & Patrol Hubs ---
    {
        "id": "pol_banani",
        "name": "Banani Police Station",
        "type": "police",
        "latitude": 23.7925,
        "longitude": 90.4078,
        "address": "Road 11, Block D, Banani, Dhaka",
        "contact_number": "+8801713373155",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "Fast-response patrol unit active"
    },
    {
        "id": "pol_gulshan",
        "name": "Gulshan Model Police Station",
        "type": "police",
        "latitude": 23.7892,
        "longitude": 90.4178,
        "address": "Road 36, Gulshan-2, Dhaka",
        "contact_number": "+8801713373156",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "Diplomatic zone 24/7 security control"
    },
    {
        "id": "pol_tejgaon_ind",
        "name": "Tejgaon Industrial Police Station",
        "type": "police",
        "latitude": 23.7598,
        "longitude": 90.3905,
        "address": "Tejgaon Industrial Area, Dhaka",
        "contact_number": "+8801713373160",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "Industrial belt security division"
    },
    {
        "id": "pol_tejgaon_model",
        "name": "Tejgaon Model Police Station",
        "type": "police",
        "latitude": 23.7548,
        "longitude": 90.3912,
        "address": "Farmgate, Tejgaon, Dhaka",
        "contact_number": "+8801713373161",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "Near Farmgate Metro & bus terminal"
    },
    {
        "id": "pol_dhanmondi",
        "name": "Dhanmondi Model Police Station",
        "type": "police",
        "latitude": 23.7465,
        "longitude": 90.3760,
        "address": "Road 27, Dhanmondi, Dhaka",
        "contact_number": "+8801713373157",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "Near Dhanmondi Lake & educational hub"
    },
    {
        "id": "pol_uttara_east",
        "name": "Uttara East Police Station",
        "type": "police",
        "latitude": 23.8728,
        "longitude": 90.3984,
        "address": "Sector 3, Uttara, Dhaka",
        "contact_number": "+8801713373158",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "Near Airport Railway & Dhaka Airport"
    },
    {
        "id": "pol_uttara_west",
        "name": "Uttara West Police Station",
        "type": "police",
        "latitude": 23.8711,
        "longitude": 90.3842,
        "address": "Sector 11, Uttara, Dhaka",
        "contact_number": "+8801713373162",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "Near Sector 11 women & children zone"
    },
    {
        "id": "pol_mirpur",
        "name": "Mirpur Model Police Station",
        "type": "police",
        "latitude": 23.8071,
        "longitude": 90.3686,
        "address": "Section 2, Mirpur, Dhaka",
        "contact_number": "+8801713373159",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "Beside Mirpur Stadium & Metro 10"
    },
    {
        "id": "pol_shahbagh",
        "name": "Shahbagh Police Station",
        "type": "police",
        "latitude": 23.7381,
        "longitude": 90.3957,
        "address": "Shahbagh Intersection, Dhaka",
        "contact_number": "+8801713373163",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "Adjacent to DU, BSMMU & BIRDEM"
    },
    {
        "id": "pol_ramna",
        "name": "Ramna Police Station",
        "type": "police",
        "latitude": 23.7410,
        "longitude": 90.4042,
        "address": "Minto Road, Ramna, Dhaka",
        "contact_number": "+8801713373164",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "Central police control corridor"
    },
    {
        "id": "pol_badda",
        "name": "Badda Police Station",
        "type": "police",
        "latitude": 23.7806,
        "longitude": 90.4267,
        "address": "Pragati Sarani, Middle Badda, Dhaka",
        "contact_number": "+8801713373166",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "Pragati Sarani arterial corridor"
    },
    {
        "id": "pol_mohammadpur",
        "name": "Mohammadpur Police Station",
        "type": "police",
        "latitude": 23.7562,
        "longitude": 90.3614,
        "address": "Asad Gate, Mohammadpur, Dhaka",
        "contact_number": "+8801713373167",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "Residential hub patrol post"
    },
    {
        "id": "pol_lalbagh",
        "name": "Lalbagh Police Station",
        "type": "police",
        "latitude": 23.7198,
        "longitude": 90.3882,
        "address": "Lalbagh Fort Road, Old Dhaka",
        "contact_number": "+8801713373168",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "Old Dhaka historic patrol zone"
    },
    {
        "id": "pol_paltan",
        "name": "Paltan Model Police Station",
        "type": "police",
        "latitude": 23.7342,
        "longitude": 90.4128,
        "address": "Naya Paltan, Dhaka",
        "contact_number": "+8801713373169",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "Commercial district response unit"
    },

    # --- Hospitals & Emergency Medical Centers ---
    {
        "id": "hosp_united",
        "name": "United Hospital",
        "type": "hospital",
        "latitude": 23.8052,
        "longitude": 90.4158,
        "address": "Plot 15, Road 71, Gulshan-2, Dhaka",
        "contact_number": "10666",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "24/7 trauma & emergency department"
    },
    {
        "id": "hosp_kurmitola",
        "name": "Kurmitola General Hospital",
        "type": "hospital",
        "latitude": 23.8223,
        "longitude": 90.4124,
        "address": "Airport Road, Cantonment, Dhaka",
        "contact_number": "+880255067080",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "Public general hospital with 24/7 casualty"
    },
    {
        "id": "hosp_square",
        "name": "Square Hospital",
        "type": "hospital",
        "latitude": 23.7531,
        "longitude": 90.3817,
        "address": "18/F Bir Uttam Qazi Nuruzzaman Sarak, Dhaka",
        "contact_number": "10616",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "24/7 critical care & ambulance"
    },
    {
        "id": "hosp_dmc",
        "name": "Dhaka Medical College Hospital",
        "type": "hospital",
        "latitude": 23.7258,
        "longitude": 90.3976,
        "address": "Secretariat Road, Bakshibazar, Dhaka",
        "contact_number": "+880255165088",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "Largest tertiary emergency hospital in BD"
    },
    {
        "id": "hosp_evercare",
        "name": "Evercare Hospital Dhaka",
        "type": "hospital",
        "latitude": 23.8101,
        "longitude": 90.4312,
        "address": "Plot 81, Block E, Bashundhara R/A, Dhaka",
        "contact_number": "10678",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "JCI accredited 24/7 emergency unit"
    },
    {
        "id": "hosp_bsmmu",
        "name": "BSMMU (PG Hospital)",
        "type": "hospital",
        "latitude": 23.7397,
        "longitude": 90.3958,
        "address": "Shahbagh, Dhaka",
        "contact_number": "+880255165760",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "Central medical university hospital"
    },
    {
        "id": "hosp_birdem",
        "name": "BIRDEM General Hospital",
        "type": "hospital",
        "latitude": 23.7388,
        "longitude": 90.3952,
        "address": "122 Kazi Nazrul Islam Avenue, Shahbagh, Dhaka",
        "contact_number": "+88029661551",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "24/7 emergency care & pharmacy"
    },
    {
        "id": "hosp_labaid",
        "name": "Labaid Specialized Hospital",
        "type": "hospital",
        "latitude": 23.7431,
        "longitude": 90.3824,
        "address": "House 06, Road 04, Dhanmondi, Dhaka",
        "contact_number": "10606",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "Emergency cardiac & general care"
    },
    {
        "id": "hosp_ibn_sina",
        "name": "Ibn Sina Hospital Dhanmondi",
        "type": "hospital",
        "latitude": 23.7490,
        "longitude": 90.3725,
        "address": "House 48, Road 9/A, Dhanmondi, Dhaka",
        "contact_number": "10615",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "Round-the-clock emergency assistance"
    },
    {
        "id": "hosp_cmh",
        "name": "Combined Military Hospital (CMH)",
        "type": "hospital",
        "latitude": 23.8187,
        "longitude": 90.3985,
        "address": "Dhaka Cantonment, Dhaka",
        "contact_number": "+88028750011",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "Military-grade 24/7 emergency complex"
    },

    # --- MRT Line 6 Safe Transit Stations ---
    {
        "id": "metro_uttara_north",
        "name": "Uttara North Metro Station",
        "type": "metro",
        "latitude": 23.8741,
        "longitude": 90.3972,
        "address": "Diabari, Sector 15, Uttara, Dhaka",
        "contact_number": "16163",
        "is_verified": True,
        "operating_hours": "06:00 AM - 11:00 PM",
        "notes": "CCTV guarded, security gates active"
    },
    {
        "id": "metro_uttara_center",
        "name": "Uttara Center Metro Station",
        "type": "metro",
        "latitude": 23.8640,
        "longitude": 90.3920,
        "address": "Sector 16, Uttara, Dhaka",
        "contact_number": "16163",
        "is_verified": True,
        "operating_hours": "06:00 AM - 11:00 PM",
        "notes": "CCTV monitored safe corridor"
    },
    {
        "id": "metro_uttara_south",
        "name": "Uttara South Metro Station",
        "type": "metro",
        "latitude": 23.8475,
        "longitude": 90.3855,
        "address": "Sector 17, Uttara, Dhaka",
        "contact_number": "16163",
        "is_verified": True,
        "operating_hours": "06:00 AM - 11:00 PM",
        "notes": "Station security guards present"
    },
    {
        "id": "metro_pallabi",
        "name": "Pallabi Metro Station",
        "type": "metro",
        "latitude": 23.8248,
        "longitude": 90.3644,
        "address": "Mirpur 12, Pallabi, Dhaka",
        "contact_number": "16163",
        "is_verified": True,
        "operating_hours": "06:00 AM - 11:00 PM",
        "notes": "Police patrol checkpoint nearby"
    },
    {
        "id": "metro_mirpur11",
        "name": "Mirpur 11 Metro Station",
        "type": "metro",
        "latitude": 23.8164,
        "longitude": 90.3660,
        "address": "Mirpur 11, Dhaka",
        "contact_number": "16163",
        "is_verified": True,
        "operating_hours": "06:00 AM - 11:00 PM",
        "notes": "Well-lit entrance with CCTV"
    },
    {
        "id": "metro_mirpur10",
        "name": "Mirpur 10 Metro Station",
        "type": "metro",
        "latitude": 23.8069,
        "longitude": 90.3687,
        "address": "Mirpur 10 Roundabout, Dhaka",
        "contact_number": "16163",
        "is_verified": True,
        "operating_hours": "06:00 AM - 11:00 PM",
        "notes": "Major transit hub with round-the-clock police"
    },
    {
        "id": "metro_kazipara",
        "name": "Kazipara Metro Station",
        "type": "metro",
        "latitude": 23.7998,
        "longitude": 90.3712,
        "address": "Kazipara, Rokeya Sarani, Dhaka",
        "contact_number": "16163",
        "is_verified": True,
        "operating_hours": "06:00 AM - 11:00 PM",
        "notes": "Safe transit access point"
    },
    {
        "id": "metro_shewrapara",
        "name": "Shewrapara Metro Station",
        "type": "metro",
        "latitude": 23.7937,
        "longitude": 90.3735,
        "address": "Shewrapara, Rokeya Sarani, Dhaka",
        "contact_number": "16163",
        "is_verified": True,
        "operating_hours": "06:00 AM - 11:00 PM",
        "notes": "Near Banani-Mirpur link"
    },
    {
        "id": "metro_agargaon",
        "name": "Agargaon Metro Station",
        "type": "metro",
        "latitude": 23.7785,
        "longitude": 90.3789,
        "address": "Sher-e-Bangla Nagar, Agargaon, Dhaka",
        "contact_number": "16163",
        "is_verified": True,
        "operating_hours": "06:00 AM - 11:00 PM",
        "notes": "Government administrative zone"
    },
    {
        "id": "metro_bijoy_sarani",
        "name": "Bijoy Sarani Metro Station",
        "type": "metro",
        "latitude": 23.7662,
        "longitude": 90.3842,
        "address": "Bijoy Sarani, Tejgaon, Dhaka",
        "contact_number": "16163",
        "is_verified": True,
        "operating_hours": "06:00 AM - 11:00 PM",
        "notes": "Military museum and safe boulevard"
    },
    {
        "id": "metro_farmgate",
        "name": "Farmgate Metro Station",
        "type": "metro",
        "latitude": 23.7570,
        "longitude": 90.3880,
        "address": "Farmgate Intersection, Dhaka",
        "contact_number": "16163",
        "is_verified": True,
        "operating_hours": "06:00 AM - 11:00 PM",
        "notes": "High footfall safe intersection"
    },
    {
        "id": "metro_karwan_bazar",
        "name": "Karwan Bazar Metro Station",
        "type": "metro",
        "latitude": 23.7505,
        "longitude": 90.3920,
        "address": "Kazi Nazrul Islam Avenue, Dhaka",
        "contact_number": "16163",
        "is_verified": True,
        "operating_hours": "06:00 AM - 11:00 PM",
        "notes": "Media & commercial district"
    },
    {
        "id": "metro_shahbagh",
        "name": "Shahbagh Metro Station",
        "type": "metro",
        "latitude": 23.7385,
        "longitude": 90.3955,
        "address": "Shahbagh Square, Dhaka",
        "contact_number": "16163",
        "is_verified": True,
        "operating_hours": "06:00 AM - 11:00 PM",
        "notes": "Near National Museum & DU"
    },
    {
        "id": "metro_du",
        "name": "Dhaka University Metro Station",
        "type": "metro",
        "latitude": 23.7314,
        "longitude": 90.3962,
        "address": "DU Campus, Nilkhet Road, Dhaka",
        "contact_number": "16163",
        "is_verified": True,
        "operating_hours": "06:00 AM - 11:00 PM",
        "notes": "Student & women safety corridor"
    },
    {
        "id": "metro_secretariat",
        "name": "Bangladesh Secretariat Metro Station",
        "type": "metro",
        "latitude": 23.7275,
        "longitude": 90.4048,
        "address": "Abdul Gani Road, Dhaka",
        "contact_number": "16163",
        "is_verified": True,
        "operating_hours": "06:00 AM - 11:00 PM",
        "notes": "High-security government corridor"
    },
    {
        "id": "metro_motijheel",
        "name": "Motijheel Metro Station",
        "type": "metro",
        "latitude": 23.7250,
        "longitude": 90.4168,
        "address": "Shapla Chattar, Motijheel, Dhaka",
        "contact_number": "16163",
        "is_verified": True,
        "operating_hours": "06:00 AM - 11:00 PM",
        "notes": "Terminal hub with security guards"
    },

    # --- 24/7 Women Safety Support & Security Checkpoints ---
    {
        "id": "check_emergency_999",
        "name": "National Emergency 999 Center",
        "type": "checkpoint",
        "latitude": 23.7380,
        "longitude": 90.4080,
        "address": "Abdul Gani Road, Dhaka",
        "contact_number": "999",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "National SOS & police dispatch headquarters"
    },
    {
        "id": "check_police_plaza",
        "name": "Police Plaza Security Post",
        "type": "checkpoint",
        "latitude": 23.7782,
        "longitude": 90.4153,
        "address": "Gulshan 1, Hatirjheel Link Road, Dhaka",
        "contact_number": "+88029883536",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "24/7 guarded security outpost at Hatirjheel entry"
    },
    {
        "id": "check_du_proctor",
        "name": "DU Proctor Office & Security Cell",
        "type": "checkpoint",
        "latitude": 23.7330,
        "longitude": 90.3935,
        "address": "Mall Area, Dhaka University Campus, Dhaka",
        "contact_number": "+88029661900",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "Dedicated female student security cell"
    },
    {
        "id": "check_banani_patrol",
        "name": "Banani Checkpoint & Patrol Post",
        "type": "checkpoint",
        "latitude": 23.7960,
        "longitude": 90.4045,
        "address": "Kamal Ataturk Avenue, Banani, Dhaka",
        "contact_number": "+8801713373155",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "Permanent roadside patrol checkpoint"
    },
    {
        "id": "check_hatirjheel_post",
        "name": "Hatirjheel Police Patrol Post",
        "type": "checkpoint",
        "latitude": 23.7685,
        "longitude": 90.4050,
        "address": "Rampura Bridge, Hatirjheel, Dhaka",
        "contact_number": "+8801713373170",
        "is_verified": True,
        "operating_hours": "24/7",
        "notes": "Hatirjheel security & surveillance unit"
    }
]

def build_excel(filename):
    wb = Workbook()
    ws = wb.active
    ws.title = "Safe_Zones_Catalog"
    ws.views.sheetView[0].showGridLines = True

    # Color definitions
    navy_header_fill = PatternFill(start_color="1F4E79", end_color="1F4E79", fill_type="solid")
    white_bold_font = Font(name="Calibri", size=11, bold=True, color="FFFFFF")
    
    type_fills = {
        "police": PatternFill(start_color="DDEEFD", end_color="DDEEFD", fill_type="solid"),
        "hospital": PatternFill(start_color="FFE5E5", end_color="FFE5E5", fill_type="solid"),
        "metro": PatternFill(start_color="F0E6F9", end_color="F0E6F9", fill_type="solid"),
        "checkpoint": PatternFill(start_color="DFF5E3", end_color="DFF5E3", fill_type="solid")
    }

    thin_border = Border(
        left=Side(style='thin', color='D9D9D9'),
        right=Side(style='thin', color='D9D9D9'),
        top=Side(style='thin', color='D9D9D9'),
        bottom=Side(style='thin', color='D9D9D9')
    )

    headers = [
        "id", "name", "type", "latitude", "longitude", 
        "address", "contact_number", "is_verified", 
        "operating_hours", "notes"
    ]

    # Write headers
    ws.append(headers)
    for col_idx in range(1, len(headers) + 1):
        cell = ws.cell(row=1, column=col_idx)
        cell.fill = navy_header_fill
        cell.font = white_bold_font
        cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=False)

    # Write data rows
    for row_idx, z in enumerate(safe_zones, start=2):
        row_values = [
            z["id"],
            z["name"],
            z["type"],
            z["latitude"],
            z["longitude"],
            z["address"],
            z["contact_number"],
            "TRUE" if z["is_verified"] else "FALSE",
            z["operating_hours"],
            z["notes"]
        ]
        ws.append(row_values)

        # Style data cells
        for col_idx in range(1, len(headers) + 1):
            cell = ws.cell(row=row_idx, column=col_idx)
            cell.border = thin_border
            cell.font = Font(name="Calibri", size=10)

            # Center align IDs, types, coords, status
            if col_idx in (1, 3, 4, 5, 7, 8, 9):
                cell.alignment = Alignment(horizontal="center", vertical="center")
            else:
                cell.alignment = Alignment(horizontal="left", vertical="center")

            # Soft type-based highlight
            if col_idx == 3 and z["type"] in type_fills:
                cell.fill = type_fills[z["type"]]

    # Auto-fit column widths
    for col in ws.columns:
        max_len = max(len(str(cell.value or '')) for cell in col)
        col_letter = get_column_letter(col[0].column)
        ws.column_dimensions[col_letter].width = max(max_len + 3, 12)

    # Set row height
    ws.row_dimensions[1].height = 28
    for r in range(2, len(safe_zones) + 2):
        ws.row_dimensions[r].height = 20

    wb.save(filename)
    print(f"Generated Excel: {filename}")

def build_csv(filename):
    headers = [
        "id", "name", "type", "latitude", "longitude", 
        "address", "contact_number", "is_verified", 
        "operating_hours", "notes"
    ]
    with open(filename, mode='w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=headers)
        writer.writeheader()
        writer.writerows(safe_zones)
    print(f"Generated CSV: {filename}")

def build_json(filename):
    with open(filename, mode='w', encoding='utf-8') as f:
        json.dump(safe_zones, f, indent=2, ensure_ascii=False)
    print(f"Generated JSON: {filename}")

if __name__ == "__main__":
    workspace = r"e:\1. FINAL YEAR PROJECT\WOMENS SAFETY APP"
    data_dir = os.path.join(workspace, "assets", "data")
    os.makedirs(data_dir, exist_ok=True)

    # 1. Main Excel file at workspace root for easy user opening
    root_xlsx = os.path.join(workspace, "safe_zones_database.xlsx")
    build_excel(root_xlsx)

    # 2. Excel in assets/data
    assets_xlsx = os.path.join(data_dir, "safe_zones.xlsx")
    build_excel(assets_xlsx)

    # 3. CSV file in assets/data
    assets_csv = os.path.join(data_dir, "safe_zones.csv")
    build_csv(assets_csv)

    # 4. JSON file for Flutter app assets
    assets_json = os.path.join(data_dir, "safe_zones.json")
    build_json(assets_json)
