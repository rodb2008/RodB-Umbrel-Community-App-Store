from flask import Flask, Response
import json
from gopool-api-etl_v1.py import get_combined_data # Ensure your script is importable

app = Flask(__name__)

@app.route('/widgets/stats', methods=['GET'])
def pool_widget():
    # Call your function. Umbrel widgets expect a flat JSON object for standard displays.
    # Note: Your current script returns a string of 3 JSON lines; 
    # Umbrel widgets typically prefer a single unified JSON object.
    data = get_combined_data()
    return Response(data, mimetype='application/json')

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=23000)

