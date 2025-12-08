document.addEventListener('DOMContentLoaded', function() {
    const form = document.getElementById('policyForm');
    const messageDiv = document.getElementById('message');
    const policiesList = document.getElementById('policiesList');

    // Загрузить список полисов при загрузке страницы
    loadPolicies();

    form.addEventListener('submit', async function(e) {
        e.preventDefault();
        
        const clientName = document.getElementById('clientName').value;
        const email = document.getElementById('email').value;
        
        const submitBtn = document.getElementById('submitBtn');
        submitBtn.disabled = true;
        submitBtn.textContent = 'Creating...';
        messageDiv.textContent = '';
        messageDiv.className = 'message';

        try {
            const response = await fetch('/api/policies', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({
                    client_name: clientName,
                    email: email
                })
            });

            const data = await response.json();
            
            if (response.ok) {
                messageDiv.textContent = `Policy created! ID: ${data.policy_id}, Status: ${data.status}`;
                messageDiv.className = 'message success';
                form.reset();
                loadPolicies();
            } else {
                messageDiv.textContent = `Error: ${data.error || 'Failed to create policy'}`;
                messageDiv.className = 'message error';
            }
        } catch (error) {
            messageDiv.textContent = `Error: ${error.message}`;
            messageDiv.className = 'message error';
        } finally {
            submitBtn.disabled = false;
            submitBtn.textContent = 'Create Policy';
        }
    });

    async function loadPolicies() {
        try {
            const response = await fetch('/api/policies');
            const policies = await response.json();
            
            if (policies.length === 0) {
                policiesList.innerHTML = '<p>No policies yet.</p>';
                return;
            }

            const listHTML = '<h2>Existing Policies:</h2><ul>' + 
                policies.map(policy => 
                    `<li>ID: ${policy.id}, Client: ${policy.client_name}, Email: ${policy.email}, Status: ${policy.status}, Created: ${new Date(policy.created_at).toLocaleString()}</li>`
                ).join('') + 
                '</ul>';
            
            policiesList.innerHTML = listHTML;
        } catch (error) {
            console.error('Error loading policies:', error);
        }
    }
});

