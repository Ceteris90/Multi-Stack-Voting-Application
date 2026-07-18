#!/usr/bin/env python3
"""
Simulate random voting load on local and AWS EKS environments.
Generates 10,000 random votes split between local and AWS endpoints.
"""

import requests
import random
import argparse
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
import re
import os
import subprocess
import sys

# Configuration
LOCAL_VOTE_URL = "http://localhost:8000"
DEFAULT_K8S_NAMESPACE = "voting-app"

VOTE_OPTIONS = ['a', 'b']  # a=Cats, b=Dogs
SESSION = requests.Session()
SESSION.headers.update({'User-Agent': 'VoteSimulator/1.0'})

# Statistics
stats = {
    'local_success': 0,
    'local_failed': 0,
    'aws_success': 0,
    'aws_failed': 0,
    'total_processed': 0,
    'start_time': None,
    'errors': []
}


def load_deployment_config():
    """Load simple KEY="value" pairs from scripts/deployment.config if present."""
    config_path = Path(__file__).resolve().parent / 'deployment.config'
    config = {}

    if not config_path.exists():
        return config

    for raw_line in config_path.read_text(encoding='utf-8').splitlines():
        line = raw_line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue

        key, value = line.split('=', 1)
        key = key.strip()
        value = value.strip().strip('"\'')
        config[key] = os.path.expandvars(value)

    return config


def get_kubernetes_vote_url(namespace):
    """Resolve the vote service LoadBalancer hostname from Kubernetes."""
    try:
        result = subprocess.run(
            [
                'kubectl', '-n', namespace,
                'get', 'svc', 'vote',
                '-o', 'jsonpath={.status.loadBalancer.ingress[0].hostname}'
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None

    hostname = result.stdout.strip()
    if result.returncode != 0 or not hostname:
        return None

    return f"http://{hostname}"


def resolve_aws_vote_url(cli_value=None):
    """Resolve AWS vote URL from CLI, env/config, or live Kubernetes state."""
    if cli_value:
        return cli_value

    env_candidates = [
        os.environ.get('AWS_VOTE_URL'),
        os.environ.get('PUBLIC_VOTE_URL'),
    ]
    for candidate in env_candidates:
        if candidate:
            return candidate

    config = load_deployment_config()
    config_candidates = [
        config.get('AWS_VOTE_URL'),
        config.get('PUBLIC_VOTE_URL'),
    ]
    for candidate in config_candidates:
        if candidate and not candidate.startswith('Pending '):
            return candidate

    namespace = os.environ.get('K8S_NAMESPACE') or config.get('K8S_NAMESPACE') or DEFAULT_K8S_NAMESPACE
    return get_kubernetes_vote_url(namespace)


def check_endpoint(url, label):
    """Return endpoint health information."""
    if not url:
        return False, 'URL not configured'

    try:
        response = SESSION.get(url, timeout=5)
        if response.status_code == 200:
            return True, None
        return False, f"HTTP {response.status_code}"
    except Exception as exc:
        return False, str(exc)


def get_csrf_token(url):
    """Extract CSRF token from vote page."""
    try:
        response = SESSION.get(url, timeout=5)
        response.raise_for_status()
        
        # Pattern 1: <input type="hidden" name="csrf_token" value="TOKEN" />
        match = re.search(r'<input[^>]*name=["\']csrf_token["\'][^>]*value=["\']([^"\']+)["\']', response.text)
        if match:
            return match.group(1)
        
        # Pattern 2: <input ... value="TOKEN" ... name="csrf_token" ...>
        match = re.search(r'<input[^>]*value=["\']([^"\']+)["\'][^>]*name=["\']csrf_token["\']', response.text)
        if match:
            return match.group(1)
        
        # Pattern 3: Look for any hidden input with csrf in name
        match = re.search(r'<input[^>]*type=["\']hidden["\'][^>]*csrf[^>]*value=["\']([^"\']+)["\']', response.text, re.IGNORECASE)
        if match:
            return match.group(1)
        
        # If no form field found, try using cookies (Flask-WTF can use cookie-based tokens)
        if 'csrf_token' in SESSION.cookies:
            return SESSION.cookies.get('csrf_token')
        
        return None
    except Exception as e:
        stats['errors'].append(f"CSRF extraction failed for {url}: {str(e)}")
        return None


def submit_vote(url, vote, attempt=1):
    """Submit a single vote to the endpoint."""
    try:
        # First, get the page to establish session and get CSRF token
        get_response = SESSION.get(url, timeout=5)
        get_response.raise_for_status()
        
        # Try to extract CSRF token
        csrf_token = get_csrf_token(url)
        
        # Prepare vote data
        data = {'vote': vote}
        if csrf_token:
            data['csrf_token'] = csrf_token
        
        # Submit vote
        response = SESSION.post(url, data=data, timeout=5, allow_redirects=True)
        
        if response.status_code == 200:
            return True, None
        else:
            return False, f"HTTP {response.status_code}"
    
    except requests.exceptions.Timeout:
        return False, "Timeout"
    except requests.exceptions.ConnectionError:
        return False, "Connection error"
    except Exception as e:
        return False, str(e)


def worker(vote_num, endpoint_url, vote_option):
    """Worker function for parallel vote submission."""
    success, error = submit_vote(endpoint_url, vote_option)
    
    if success:
        if 'localhost' in endpoint_url or '127.0.0.1' in endpoint_url:
            stats['local_success'] += 1
        else:
            stats['aws_success'] += 1
    else:
        if 'localhost' in endpoint_url or '127.0.0.1' in endpoint_url:
            stats['local_failed'] += 1
        else:
            stats['aws_failed'] += 1
        if error:
            stats['errors'].append(f"Vote {vote_num}: {error}")
    
    stats['total_processed'] += 1
    return success


def print_progress(processed, total):
    """Print progress bar."""
    percent = (processed / total) * 100
    bar_length = 40
    filled = int(bar_length * processed / total)
    bar = '█' * filled + '░' * (bar_length - filled)
    elapsed = time.time() - stats['start_time']
    rate = processed / elapsed if elapsed > 0 else 0
    eta = (total - processed) / rate if rate > 0 else 0
    
    sys.stdout.write(f'\r[{bar}] {percent:6.2f}% ({processed}/{total}) | {rate:.1f} votes/sec | ETA: {eta:.0f}s')
    sys.stdout.flush()


def simulate_votes(total_votes=600, num_workers=10, local_ratio=0.5):
    """Simulate votes split between local and AWS endpoints."""
    aws_vote_url = resolve_aws_vote_url()
    aws_votes = total_votes - int(total_votes * local_ratio)

    if aws_votes > 0 and not aws_vote_url:
        print("❌ AWS vote URL could not be resolved. Set --aws-vote-url, AWS_VOTE_URL, or PUBLIC_VOTE_URL.")
        sys.exit(1)

    print(f"🗳️  Vote Simulator")
    print(f"{'='*60}")
    print(f"Total votes:     {total_votes:,}")
    print(f"Workers:         {num_workers}")
    print(f"Local ratio:     {local_ratio*100:.0f}%")
    print(f"AWS ratio:       {(1-local_ratio)*100:.0f}%")
    print(f"Local endpoint:  {LOCAL_VOTE_URL}")
    print(f"AWS endpoint:    {aws_vote_url or 'disabled'}")
    print(f"{'='*60}\n")
    
    stats['start_time'] = time.time()
    
    # Calculate split
    local_votes = int(total_votes * local_ratio)
    
    print(f"Generating {local_votes:,} local votes + {aws_votes:,} AWS votes...")
    
    # Create vote tasks
    tasks = []
    for i in range(local_votes):
        vote = random.choice(VOTE_OPTIONS)
        tasks.append((i, LOCAL_VOTE_URL, vote))
    
    for i in range(local_votes, total_votes):
        vote = random.choice(VOTE_OPTIONS)
        tasks.append((i, aws_vote_url, vote))
    
    # Randomize order to mix local/AWS requests
    random.shuffle(tasks)
    
    print(f"Submitting votes with {num_workers} workers...\n")
    
    # Submit votes in parallel
    with ThreadPoolExecutor(max_workers=num_workers) as executor:
        futures = {
            executor.submit(worker, vote_num, url, vote): i 
            for i, (vote_num, url, vote) in enumerate(tasks)
        }
        
        for future in as_completed(futures):
            print_progress(stats['total_processed'], total_votes)
    
    print("\n")
    print_results()


def print_results():
    """Print summary statistics."""
    elapsed = time.time() - stats['start_time']
    
    print(f"\n{'='*60}")
    print(f"✅ VOTING SIMULATION COMPLETE")
    print(f"{'='*60}")
    print(f"Total time:       {elapsed:.1f} seconds")
    print(f"Average rate:     {stats['total_processed']/elapsed:.1f} votes/sec")
    print(f"\n📊 Results:")
    print(f"  Local endpoint:  {stats['local_success']:,} ✅ | {stats['local_failed']:,} ❌")
    print(f"  AWS endpoint:    {stats['aws_success']:,} ✅ | {stats['aws_failed']:,} ❌")
    print(f"  Total:           {stats['local_success'] + stats['aws_success']:,} ✅ | {stats['local_failed'] + stats['aws_failed']:,} ❌")
    
    success_rate = (stats['local_success'] + stats['aws_success']) / stats['total_processed'] * 100
    print(f"  Success rate:    {success_rate:.2f}%")
    
    if stats['errors']:
        print(f"\n⚠️  Errors ({len(stats['errors'])} total):")
        for error in stats['errors'][:10]:  # Show first 10 errors
            print(f"    - {error}")
        if len(stats['errors']) > 10:
            print(f"    ... and {len(stats['errors']) - 10} more")
    
    print(f"\n💡 Next steps:")
    print(f"  1. Check local results:   http://localhost:8081")
    aws_vote_url = resolve_aws_vote_url()
    if aws_vote_url:
        print(f"  2. Check AWS results:     {aws_vote_url.replace('vote', 'result')}")


def test_endpoints(local_ratio):
    """Test only the endpoints that will actually receive traffic."""
    print("🔍 Testing endpoints...\n")
    aws_vote_url = resolve_aws_vote_url()

    endpoints = {}

    if local_ratio > 0:
        endpoints['Local Vote'] = LOCAL_VOTE_URL
    else:
        print("  ⚠️  Local Vote          Skipped (local-ratio is 0.0)")

    if aws_vote_url:
        endpoints['AWS Vote'] = aws_vote_url
    elif local_ratio < 1:
        print("  ⚠️  AWS Vote            URL not configured; skipping AWS check")
    
    all_ok = True
    for name, url in endpoints.items():
        ok, error = check_endpoint(url, name)
        if ok:
            print(f"  ✅ {name:20} ({url})")
        else:
            print(f"  ❌ {name:20} {error}")
            all_ok = False
    
    print()
    return all_ok


def main():
    parser = argparse.ArgumentParser(
        description='Simulate random voting load',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Simulate 10,000 votes (50% local, 50% AWS)
  python3 simulate_votes.py

  # Simulate 1,000 votes with 8 workers
  python3 simulate_votes.py --votes 1000 --workers 8

  # Simulate 5,000 votes, 70% local / 30% AWS
  python3 simulate_votes.py --votes 5000 --local-ratio 0.7

  # Test endpoints only (don't simulate votes)
  python3 simulate_votes.py --test-only
        """
    )
    
    parser.add_argument(
        '--aws-vote-url',
        default=None,
        help='AWS vote endpoint URL. If omitted, resolve from env/config/kubectl.'
    )
    parser.add_argument(
        '--votes',
        type=int,
        default=1000,
        help='Total number of votes to simulate (default: 10000)'
    )
    parser.add_argument(
        '--workers',
        type=int,
        default=10,
        help='Number of parallel workers (default: 10)'
    )
    parser.add_argument(
        '--local-ratio',
        type=float,
        default=0.5,
        help='Ratio of votes to local endpoint (0.0-1.0, default: 0.5)'
    )
    parser.add_argument(
        '--test-only',
        action='store_true',
        help='Only test endpoints, do not simulate votes'
    )
    
    args = parser.parse_args()
    
    # Validate arguments
    if not 0 <= args.local_ratio <= 1:
        print("Error: --local-ratio must be between 0 and 1")
        sys.exit(1)
    
    if args.votes < 1:
        print("Error: --votes must be at least 1")
        sys.exit(1)
    
    if args.workers < 1:
        print("Error: --workers must be at least 1")
        sys.exit(1)

    aws_vote_url = resolve_aws_vote_url(args.aws_vote_url)
    if args.local_ratio < 1 and not aws_vote_url:
        print("Error: AWS traffic requested but AWS vote URL could not be resolved.")
        print("Set --aws-vote-url, AWS_VOTE_URL, or PUBLIC_VOTE_URL, or run with --local-ratio 1.0.")
        sys.exit(1)

    if aws_vote_url:
        os.environ['AWS_VOTE_URL'] = aws_vote_url
    
    # Test endpoints
    if not test_endpoints(args.local_ratio):
        print("⚠️  Warning: Some endpoints are not reachable.")
        if not args.test_only:
            response = input("Continue anyway? (y/n): ")
            if response.lower() != 'y':
                sys.exit(1)
    
    # Exit early if test-only
    if args.test_only:
        sys.exit(0)
    
    # Simulate votes
    try:
        simulate_votes(
            total_votes=args.votes,
            num_workers=args.workers,
            local_ratio=args.local_ratio
        )
    except KeyboardInterrupt:
        print("\n\n❌ Vote simulation interrupted by user")
        print_results()
        sys.exit(1)
    except Exception as e:
        print(f"\n❌ Error during vote simulation: {str(e)}")
        sys.exit(1)


if __name__ == '__main__':
    main()
