from flask import Flask, request, jsonify
import psycopg2
from psycopg2.extras import RealDictCursor
import pika
import os
import time
from datetime import datetime

app = Flask(__name__)

# Database configuration
DB_HOST = os.getenv('DB_HOST', 'database')
DB_NAME = os.getenv('DB_NAME', 'insurance_db')
DB_USER = os.getenv('DB_USER', 'postgres')
DB_PASSWORD = os.getenv('DB_PASSWORD', 'postgres')

# RabbitMQ configuration
RABBITMQ_HOST = os.getenv('RABBITMQ_HOST', 'rabbitmq')
RABBITMQ_QUEUE = os.getenv('RABBITMQ_QUEUE', 'policy_generation')
RABBITMQ_USER = os.getenv('RABBITMQ_USER', 'admin')
RABBITMQ_PASSWORD = os.getenv('RABBITMQ_PASSWORD', 'admin')

def get_db_connection():
    """Get database connection"""
    max_retries = 5
    retry_delay = 2
    
    for attempt in range(max_retries):
        try:
            conn = psycopg2.connect(
                host=DB_HOST,
                database=DB_NAME,
                user=DB_USER,
                password=DB_PASSWORD
            )
            return conn
        except psycopg2.OperationalError as e:
            if attempt < max_retries - 1:
                print(f"Database connection failed, retrying in {retry_delay} seconds... ({attempt + 1}/{max_retries})")
                time.sleep(retry_delay)
            else:
                raise e

def get_rabbitmq_connection():
    """Get RabbitMQ connection"""
    max_retries = 5
    retry_delay = 2
    
    for attempt in range(max_retries):
        try:
            credentials = pika.PlainCredentials(RABBITMQ_USER, RABBITMQ_PASSWORD)
            connection = pika.BlockingConnection(
                pika.ConnectionParameters(
                    host=RABBITMQ_HOST,
                    credentials=credentials
                )
            )
            return connection
        except pika.exceptions.AMQPConnectionError as e:
            if attempt < max_retries - 1:
                print(f"RabbitMQ connection failed, retrying in {retry_delay} seconds... ({attempt + 1}/{max_retries})")
                time.sleep(retry_delay)
            else:
                raise e

def init_rabbitmq_queue():
    """Initialize RabbitMQ queue - create it if it doesn't exist"""
    try:
        connection = get_rabbitmq_connection()
        channel = connection.channel()
        
        # Declare queue as durable so it persists
        channel.queue_declare(queue=RABBITMQ_QUEUE, durable=True)
        
        connection.close()
        print(f"RabbitMQ queue '{RABBITMQ_QUEUE}' initialized")
        return True
    except Exception as e:
        print(f"Error initializing RabbitMQ queue: {e}")
        return False

def send_to_queue(policy_id, client_name, email):
    """Send policy generation task to RabbitMQ"""
    try:
        connection = get_rabbitmq_connection()
        channel = connection.channel()
        
        # Ensure queue exists (declare it)
        channel.queue_declare(queue=RABBITMQ_QUEUE, durable=True)
        
        # Publish message
        message = f"{policy_id}:{client_name}:{email}"
        channel.basic_publish(
            exchange='',
            routing_key=RABBITMQ_QUEUE,
            body=message,
            properties=pika.BasicProperties(
                delivery_mode=2,  # Make message persistent
            )
        )
        
        connection.close()
        print(f"Sent policy {policy_id} to queue '{RABBITMQ_QUEUE}'")
        return True
    except Exception as e:
        print(f"Error sending to queue: {e}")
        return False

@app.route('/api/policies', methods=['POST'])
def create_policy():
    """Create a new insurance policy"""
    try:
        data = request.get_json()
        
        if not data or 'client_name' not in data or 'email' not in data:
            return jsonify({'error': 'Missing required fields: client_name, email'}), 400
        
        client_name = data['client_name']
        email = data['email']
        
        # Connect to database
        conn = get_db_connection()
        cursor = conn.cursor(cursor_factory=RealDictCursor)
        
        # Check if client exists, if not create one
        cursor.execute(
            "SELECT id FROM clients WHERE email = %s",
            (email,)
        )
        client = cursor.fetchone()
        
        if not client:
            # Create new client
            cursor.execute(
                "INSERT INTO clients (name, email) VALUES (%s, %s) RETURNING id",
                (client_name, email)
            )
            client_id = cursor.fetchone()['id']
        else:
            client_id = client['id']
        
        # Create policy
        cursor.execute(
            "INSERT INTO policies (client_id, status, created_at) VALUES (%s, %s, %s) RETURNING id",
            (client_id, 'processing', datetime.now())
        )
        policy = cursor.fetchone()
        policy_id = policy['id']
        
        conn.commit()
        cursor.close()
        conn.close()
        
        # Send to RabbitMQ queue
        send_to_queue(policy_id, client_name, email)
        
        return jsonify({
            'policy_id': policy_id,
            'status': 'processing'
        }), 201
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/policies', methods=['GET'])
def get_policies():
    """Get all policies"""
    try:
        conn = get_db_connection()
        cursor = conn.cursor(cursor_factory=RealDictCursor)
        
        cursor.execute("""
            SELECT p.id, c.name as client_name, c.email, p.status, p.created_at
            FROM policies p
            JOIN clients c ON p.client_id = c.id
            ORDER BY p.created_at DESC
        """)
        
        policies = cursor.fetchall()
        
        cursor.close()
        conn.close()
        
        # Convert to list of dicts
        result = []
        for policy in policies:
            result.append({
                'id': policy['id'],
                'client_name': policy['client_name'],
                'email': policy['email'],
                'status': policy['status'],
                'created_at': policy['created_at'].isoformat()
            })
        
        return jsonify(result), 200
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/health', methods=['GET'])
@app.route('/api/health', methods=['GET'])
def health():
    """Health check endpoint"""
    return jsonify({'status': 'healthy'}), 200

if __name__ == '__main__':
    # Initialize RabbitMQ queue on startup
    print("Initializing RabbitMQ queue...")
    init_rabbitmq_queue()
    
    app.run(host='0.0.0.0', port=5000, debug=True)

