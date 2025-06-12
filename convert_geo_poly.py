import json

def geojson_to_poly(geojson_file, poly_file):
    """
    Convertit un fichier GeoJSON en format .poly
    """
    
    # Lire le fichier GeoJSON
    with open(geojson_file, 'r', encoding='utf-8') as f:
        data = json.load(f)
    
    with open(poly_file, 'w', encoding='utf-8') as f:
        # En-tête du fichier .poly
        f.write("none\n")
        
        polygon_count = 1
        
        for feature in data['features']:
            geometry = feature['geometry']
            
            if geometry['type'] == 'Polygon':
                # Pour chaque polygone
                for ring_idx, ring in enumerate(geometry['coordinates']):
                    section_name = f"{polygon_count}"
                    if ring_idx > 0:  # Trous dans le polygone
                        section_name = f"!{polygon_count}_{ring_idx}"
                    
                    f.write(f"{section_name}\n")
                    
                    # Écrire les coordonnées (lon lat)
                    for coord in ring:
                        lon, lat = coord[0], coord[1]
                        f.write(f"   {lon:.7f}   {lat:.7f}\n")
                    
                    f.write("END\n")
                
                polygon_count += 1
            
            elif geometry['type'] == 'MultiPolygon':
                # Pour chaque multipolygone
                for poly_idx, polygon in enumerate(geometry['coordinates']):
                    for ring_idx, ring in enumerate(polygon):
                        section_name = f"{polygon_count}"
                        if ring_idx > 0:  # Trous dans le polygone
                            section_name = f"!{polygon_count}_{ring_idx}"
                        
                        f.write(f"{section_name}\n")
                        
                        # Écrire les coordonnées (lon lat)
                        for coord in ring:
                            lon, lat = coord[0], coord[1]
                            f.write(f"   {lon:.7f}   {lat:.7f}\n")
                        
                        f.write("END\n")
                    
                    polygon_count += 1
        
        # Fin du fichier
        f.write("END\n")

# Utilisation
geojson_to_poly('./polygon/polygon_fr_esp.geojson', './polygon/polygon_fr_esp.poly')
print("Conversion terminée ! Le fichier output.poly a été créé.")