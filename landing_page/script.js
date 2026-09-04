const APP_CONFIG = window.EDUSITE_CONFIG || {
    apiBaseUrl: 'https://api.example.com',
    requireHttpsApi: true,
};

document.addEventListener('DOMContentLoaded', () => {
    initParticles();
});

function initParticles() {
    if (typeof particlesJS !== 'undefined') {
        particlesJS('particles-js', {
            "particles": {
                "number": { "value": 80, "density": { "enable": true, "value_area": 800 } },
                "color": { "value": "#00F0FF" },
                "shape": { "type": "circle" },
                "opacity": { "value": 0.5, "random": false },
                "size": { "value": 3, "random": true },
                "line_linked": {
                    "enable": true,
                    "distance": 150,
                    "color": "#00F0FF",
                    "opacity": 0.2,
                    "width": 1
                },
                "move": {
                    "enable": true,
                    "speed": 2,
                    "direction": "none",
                    "random": false,
                    "straight": false,
                    "out_mode": "out",
                    "bounce": false
                }
            },
            "interactivity": {
                "detect_on": "canvas",
                "events": {
                    "onhover": { "enable": true, "mode": "grab" },
                    "onclick": { "enable": true, "mode": "push" },
                    "resize": true
                },
                "modes": {
                    "grab": { "distance": 140, "line_linked": { "opacity": 1 } },
                    "push": { "particles_nb": 4 }
                }
            },
            "retina_detect": true
        });
    }
}

function switchTab(tabId) {
    const tabs = document.querySelectorAll('.tab-btn');
    tabs.forEach(tab => tab.classList.remove('active'));
    
    event.target.classList.add('active');

    const grids = document.querySelectorAll('.platforms-grid');
    grids.forEach(grid => grid.classList.add('hidden'));

    document.getElementById(`${tabId}-grid`).classList.remove('hidden');
}

function getApiBaseUrl() {
    const base = APP_CONFIG.apiBaseUrl || '';
    if (APP_CONFIG.requireHttpsApi && base.startsWith('http://')) {
        throw new Error('Insecure API URL: HTTPS is required');
    }
    return base.replace(/\/$/, '');
}

async function secureApiRequest(path, options = {}) {
    const url = `${getApiBaseUrl()}${path}`;
    const response = await fetch(url, {
        method: options.method || 'GET',
        headers: {
            'Content-Type': 'application/json',
            ...(options.token ? { Authorization: `****** } : {}),
            ...(options.headers || {}),
        },
        body: options.body ? JSON.stringify(options.body) : undefined,
    });

    if (!response.ok) {
        const payload = await response.json().catch(() => ({}));
        throw new Error(payload.error || `API request failed (${response.status})`);
    }
    return response.json();
}

// Smooth scrolling for anchor links
document.querySelectorAll('a[href^="#"]').forEach(anchor => {
    anchor.addEventListener('click', function (e) {
        const targetId = this.getAttribute('href');
        if (targetId === '#') return;
        
        const targetElement = document.querySelector(targetId);
        if (targetElement) {
            e.preventDefault();
            targetElement.scrollIntoView({
                behavior: 'smooth'
            });
        }
    });
});
