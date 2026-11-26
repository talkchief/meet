#!/usr/bin/env python3
"""Prove the Meet pod bases are provider-neutral and the Hetzner component renders what the cluster runs.

The bases under k8s-pods/<pod>/k8s hold no Hetzner Cloud value; everything only Hetzner understands
(the meet-lb annotations, the hcloud Cluster Autoscaler) is in the kustomize Component
k8s-pods/overlays/hetzner, which the cluster overlay k8s-pods/overlays/cowork includes. Another
provider adds one component next to it (k8s-pods/GCP-PORTING.md).

  python3 scripts/test-provider-overlays.py                      neutrality and render checks
  python3 scripts/test-provider-overlays.py --baseline REF       ... and the cluster overlay renders
                                                                 the same objects as at REF (and the
                                                                 same bytes, when kustomize or kubectl
                                                                 is on PATH)

Run with --baseline after any change meant to leave the Hetzner cluster's manifests as they are: the
split itself was proven against 4fced6017d29 (PR #18's head before it). No cluster, no network.
Needs Python 3 with PyYAML and git.
"""

import argparse
import copy
import difflib
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

import yaml

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ------------------------------------------------------------------ what this repository holds
# (current entry point, the same entry point's path at a baseline from before the split)
ENTRY_POINTS = [('k8s-pods/overlays/cowork', 'k8s-pods/overlays/cowork')]
ARCHIVE_PATHS = ['k8s-pods']
# Bases that must render without a provider value (comments never reach a render).
NEUTRAL = ['k8s-pods/%s/k8s' % pod for pod in
           ('meet-namespace', 'meet-asap', 'meet-events', 'meet-shard', 'meet-haproxy', 'meet-jvb')] + ['k8s-pods/meet-jvb/keda']
PROVIDER_PATTERNS = [r'hetzner', r'hcloud', r'talos', r'your-objectstorage\.com']
# Whole bases that exist only for one provider; composed only through that provider's component.
PROVIDER_BOUND = {
    'k8s-pods/cluster-autoscaler/k8s': 'Cluster Autoscaler with --cloud-provider=hetzner (hcloud node groups from the '
                                       'Talos image); GKE autoscales node pools itself (GCP-PORTING.md)',
}
# (kind, name prefix, base, reason): a provider value a base keeps on purpose.
EXEMPT = [
    ('ConfigMap', 'meet-jvb', 'k8s-pods/meet-jvb/k8s',
     'jvb_sidecar.py defaults METADATA_URL/ZONE_URL to the Hetzner metadata service (public IPv4, zone); '
     'another provider sets both and its metadata header (GCP-PORTING.md, "Bridges")'),
    ('ConfigMap', 'meet-haproxy', 'k8s-pods/meet-haproxy/k8s',
     'a comment in haproxy.cfg.template names the Hetzner load balancer: text only, and editing it would '
     'roll both HAProxy pods for nothing'),
]
OVERLAY = 'k8s-pods/overlays/hetzner'


def extra_checks(check):
    comp = kustomization(OVERLAY)
    check(comp.get('kind') == 'Component', '%s is a kustomize Component' % OVERLAY)
    cowork = kustomization('k8s-pods/overlays/cowork')
    check(cowork.get('components') == ['../hetzner'], 'k8s-pods/overlays/cowork includes the Hetzner component, and only it')
    check(not any('cluster-autoscaler' in r for r in cowork.get('resources', [])),
          'the provider-bound Cluster Autoscaler comes in through the Hetzner component only')
    lb = [o for o in render('k8s-pods/overlays/cowork') if o['kind'] == 'Service' and o['metadata']['name'] == 'meet-haproxy']
    ann = lb[0]['metadata'].get('annotations', {}) if lb else {}
    check(lb and ann.get('load-balancer.hetzner.cloud/name') == 'cowork-meet-lb' and ann.get('load-balancer.hetzner.cloud/location') == 'fsn1',
          'the cluster overlay gives meet-haproxy the load balancer annotations, as cowork-meet-lb in fsn1 (zone1; %d)' % len(ann))
    base = [o for o in render('k8s-pods/meet-haproxy/k8s') if o['kind'] == 'Service' and o['metadata']['name'] == 'meet-haproxy']
    check(base and base[0]['spec']['type'] == 'LoadBalancer' and base[0]['spec'].get('externalTrafficPolicy') == 'Local'
          and not base[0]['metadata'].get('annotations'),
          'the meet-haproxy base is a plain LoadBalancer Service (externalTrafficPolicy Local, no annotations)')


# ------------------------------------------------------------------ the renderer (shared by the three repositories)
# A deliberately small kustomize for the features these trees use: resources (files and
# directories), components, namespace, images, configMapGenerator (files, envs, literals, options,
# behavior create/merge/replace), generatorOptions and patches (strategic merge of maps, JSON 6902).
# It refuses anything else, and a strategic-merge patch that holds a list (kustomize merges lists by
# schema-specific keys this renderer does not model). It does not rewrite references to generated
# ConfigMap names or hash them like kustomize; both sides of a comparison go through the same code,
# so that cannot hide a difference. Real kustomize, when present, is the byte-for-byte check.

KUST_KEYS = {'apiVersion', 'kind', 'resources', 'components', 'namespace', 'images',
             'configMapGenerator', 'generatorOptions', 'patches'}
GEN_KEYS = {'name', 'namespace', 'behavior', 'files', 'envs', 'literals', 'options'}
CLUSTER_SCOPED = {'Namespace', 'ClusterRole', 'ClusterRoleBinding', 'CustomResourceDefinition',
                  'StorageClass', 'PriorityClass', 'PersistentVolume', 'ValidatingAdmissionPolicy',
                  'ValidatingAdmissionPolicyBinding', 'ValidatingWebhookConfiguration',
                  'MutatingWebhookConfiguration', 'APIService', 'IngressClass', 'GatewayClass',
                  'CiliumClusterwideNetworkPolicy', 'ClusterIssuer', 'RuntimeClass', 'CSIDriver'}


class RenderError(Exception):
    pass


def load_docs(path):
    with open(path, encoding='utf-8') as handle:
        return [doc for doc in yaml.safe_load_all(handle) if doc is not None]


def kustomization(directory):
    for name in ('kustomization.yaml', 'kustomization.yml', 'Kustomization'):
        path = os.path.join(directory, name)
        if os.path.isfile(path):
            return load_docs(path)[0] or {}
    raise RenderError('no kustomization in %s' % directory)


def smp(dst, patch, where):
    for key, value in patch.items():
        if str(key).startswith('$'):
            raise RenderError('%s: strategic-merge directive %s is not supported' % (where, key))
        if value is None:
            dst.pop(key, None)
        elif isinstance(value, list):
            raise RenderError('%s: a list (%s) in a strategic-merge patch; use a JSON 6902 patch' % (where, key))
        elif isinstance(value, dict) and isinstance(dst.get(key), dict):
            smp(dst[key], value, where)
        else:
            dst[key] = copy.deepcopy(value)


def pointer(doc, path, where):
    parts = [p.replace('~1', '/').replace('~0', '~') for p in path.split('/')[1:]]
    parent = doc
    for part in parts[:-1]:
        parent = parent[int(part)] if isinstance(parent, list) else parent[part]
    return parent, parts[-1]


def json6902(doc, ops, where):
    for op in ops:
        try:
            parent, last = pointer(doc, op['path'], where)
            if op['op'] in ('add', 'replace'):
                if isinstance(parent, list):
                    index = len(parent) if last == '-' else int(last)
                    if op['op'] == 'add':
                        parent.insert(index, copy.deepcopy(op['value']))
                    else:
                        parent[index] = copy.deepcopy(op['value'])
                else:
                    if op['op'] == 'replace' and last not in parent:
                        raise KeyError(last)
                    parent[last] = copy.deepcopy(op['value'])
            elif op['op'] == 'remove':
                if isinstance(parent, list):
                    del parent[int(last)]
                else:
                    del parent[last]
            elif op['op'] == 'test':
                value = parent[int(last)] if isinstance(parent, list) else parent[last]
                if value != op['value']:
                    raise RenderError('%s: test failed at %s' % (where, op['path']))
            else:
                raise RenderError('%s: JSON 6902 op %s is not supported' % (where, op['op']))
        except (KeyError, IndexError, ValueError, TypeError) as err:
            raise RenderError('%s: %s %s does not apply (%r)' % (where, op.get('op'), op.get('path'), err))


def selected(obj, target):
    group, _, version = obj.get('apiVersion', '').rpartition('/')
    meta = obj.get('metadata', {})
    return all((
        target.get('kind') in (None, obj.get('kind')),
        target.get('name') in (None, meta.get('name')),
        target.get('namespace') in (None, meta.get('namespace')),
        target.get('group') in (None, group),
        target.get('version') in (None, version),
    ))


def set_images(node, images):
    if isinstance(node, dict):
        for key, value in node.items():
            if key in ('containers', 'initContainers') and isinstance(value, list):
                for container in value:
                    image = container.get('image') if isinstance(container, dict) else None
                    if not isinstance(image, str):
                        continue
                    name = re.split(r'[@]', image)[0]
                    name = name.rsplit(':', 1)[0] if ':' in name.split('/')[-1] else name
                    for spec in images:
                        if spec['name'] == name:
                            new = spec.get('newName', name)
                            if spec.get('digest'):
                                new += '@' + spec['digest']
                            elif spec.get('newTag'):
                                new += ':' + str(spec['newTag'])
                            else:
                                new = image.replace(name, spec.get('newName', name), 1)
                            container['image'] = new
            set_images(value, images)
    elif isinstance(node, list):
        for item in node:
            set_images(item, images)


def read_env(path):
    data = {}
    with open(path, encoding='utf-8') as handle:
        for line in handle:
            line = line.strip()
            if line and not line.startswith('#'):
                key, _, value = line.partition('=')
                data[key] = value
    return data


def generate(directory, kust, ra):
    defaults = kust.get('generatorOptions', {})
    for gen in kust.get('configMapGenerator', []):
        if set(gen) - GEN_KEYS:
            raise RenderError('%s: configMapGenerator keys %s' % (directory, sorted(set(gen) - GEN_KEYS)))
        data = {}
        for entry in gen.get('files', []):
            key, _, src = entry.rpartition('=') if '=' in entry else ('', '', entry)
            with open(os.path.join(directory, src), encoding='utf-8') as handle:
                data[key or os.path.basename(src)] = handle.read()
        for entry in gen.get('envs', []):
            data.update(read_env(os.path.join(directory, entry)))
        for literal in gen.get('literals', []):
            key, _, value = literal.partition('=')
            data[key] = value
        options = dict(defaults, **gen.get('options', {}))
        behavior = gen.get('behavior', 'create')
        if behavior in ('merge', 'replace'):
            hits = [o for o in ra if o['kind'] == 'ConfigMap' and o['metadata']['name'] == gen['name']
                    and gen.get('namespace') in (None, o['metadata'].get('namespace'))]
            if len(hits) != 1:
                raise RenderError('%s: %s ConfigMap %s matches %d objects' % (directory, behavior, gen['name'], len(hits)))
            hits[0]['data'] = dict(hits[0].get('data', {}), **data) if behavior == 'merge' else data
            continue
        meta = {'name': gen['name']}
        if gen.get('namespace'):
            meta['namespace'] = gen['namespace']
        for field in ('labels', 'annotations'):
            if options.get(field):
                meta[field] = dict(options[field])
        ra.append({'apiVersion': 'v1', 'kind': 'ConfigMap', 'metadata': meta, 'data': data,
                   '__hash__': not options.get('disableNameSuffixHash', False)})


def transform(directory, kust, ra):
    namespace = kust.get('namespace')
    if namespace:
        for obj in ra:
            if obj.get('kind') not in CLUSTER_SCOPED:
                obj.setdefault('metadata', {})['namespace'] = namespace
    if kust.get('images'):
        set_images(ra, kust['images'])
    for number, entry in enumerate(kust.get('patches', [])):
        where = '%s patches[%d]' % (directory, number)
        if 'path' in entry:
            with open(os.path.join(directory, entry['path']), encoding='utf-8') as handle:
                text = handle.read()
        else:
            text = entry['patch']
        docs = [d for d in yaml.safe_load_all(text) if d is not None]
        if len(docs) == 1 and isinstance(docs[0], list):
            targets = [o for o in ra if selected(o, entry.get('target') or {})]
            if not targets:
                raise RenderError('%s: the JSON 6902 patch matches no object' % where)
            for obj in targets:
                json6902(obj, docs[0], where)
            continue
        for patch in docs:
            target = entry.get('target') or {'kind': patch.get('kind'), 'name': patch['metadata']['name'],
                                             'namespace': patch['metadata'].get('namespace')}
            targets = [o for o in ra if selected(o, target)]
            if len(targets) != 1 and not entry.get('target'):
                raise RenderError('%s: the patch for %s %s matches %d objects' % (where, target['kind'], target['name'], len(targets)))
            if not targets:
                raise RenderError('%s: the patch matches no object' % where)
            for obj in targets:
                smp(obj, patch, where)


def accumulate(directory, ra, component):
    kust = kustomization(directory)
    if set(kust) - KUST_KEYS:
        raise RenderError('%s: kustomization keys %s are not supported' % (directory, sorted(set(kust) - KUST_KEYS)))
    if (kust.get('kind', 'Kustomization') == 'Component') != component:
        raise RenderError('%s: kind %s used as %s' % (directory, kust.get('kind'), 'component' if component else 'resource'))
    own = ra if component else []
    for res in kust.get('resources', []):
        path = os.path.normpath(os.path.join(directory, res))
        if os.path.isdir(path):
            sub = []
            accumulate(path, sub, False)
            own.extend(sub)
        else:
            own.extend(load_docs(path))
    for comp in kust.get('components', []):
        accumulate(os.path.normpath(os.path.join(directory, comp)), own, True)
    generate(directory, kust, own)
    transform(directory, kust, own)
    if not component:
        ra.extend(own)


def render(directory):
    ra = []
    accumulate(directory, ra, False)
    for obj in ra:
        if obj.pop('__hash__', False):
            digest = hashlib.sha256(json.dumps(obj, sort_keys=True).encode()).hexdigest()[:10]
            obj['metadata']['name'] += '-' + digest
    return sorted(ra, key=identity)


def identity(obj):
    meta = obj.get('metadata', {})
    return (obj.get('apiVersion', ''), obj.get('kind', ''), meta.get('namespace') or '', meta.get('name', ''))


def kustomize_tool(explicit):
    if explicit:
        return [explicit, 'build']
    if shutil.which('kustomize'):
        return ['kustomize', 'build']
    if shutil.which('kubectl'):
        return ['kubectl', 'kustomize']
    return None


def kustomize_render(tool, directory):
    result = subprocess.run(tool + [directory], capture_output=True, text=True)
    if result.returncode:
        raise RenderError('%s %s failed: %s' % (' '.join(tool), directory, result.stderr.strip()))
    return result.stdout


def extract(ref, paths, dest):
    archive = subprocess.run(['git', '-C', REPO, 'archive', '--format=tar', ref] + paths,
                             capture_output=True, check=True).stdout
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        if hasattr(tarfile, 'data_filter'):
            tar.extractall(dest, filter='data')
        else:
            tar.extractall(dest)


def describe_diff(old, new):
    old_ids = dict((identity(o), o) for o in old)
    new_ids = dict((identity(o), o) for o in new)
    lines = []
    for key in sorted(set(old_ids) | set(new_ids)):
        if key not in new_ids:
            lines.append('  only in the baseline: %s' % '/'.join(key))
        elif key not in old_ids:
            lines.append('  only now: %s' % '/'.join(key))
        elif old_ids[key] != new_ids[key]:
            a = yaml.safe_dump(old_ids[key], sort_keys=True).splitlines()
            b = yaml.safe_dump(new_ids[key], sort_keys=True).splitlines()
            lines.append('  differs: %s' % '/'.join(key))
            lines.extend('    ' + l for l in list(difflib.unified_diff(a, b, 'baseline', 'now', lineterm=''))[2:40])
    return '\n'.join(lines)


FAILURES = []


def check(condition, message):
    print('%s: %s' % ('PASS' if condition else 'FAIL', message))
    if not condition:
        FAILURES.append(message)
    return condition


def scan_neutral(directory, patterns, exempt):
    """Provider-specific values left in a base render (comments never reach a render)."""
    found = []
    for obj in render(directory):
        if any(obj['kind'] == kind and obj['metadata']['name'].startswith(name) for kind, name, _ in exempt):
            continue
        text = yaml.safe_dump(obj, sort_keys=True)
        for pattern in patterns:
            for match in re.finditer(pattern, text, re.I):
                line = text[text.rfind('\n', 0, match.start()) + 1:text.find('\n', match.end())]
                found.append('%s %s: %s' % (obj['kind'], obj['metadata']['name'], line.strip()[:140]))
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--baseline', help='git ref to compare the Hetzner entry points against')
    parser.add_argument('--kustomize', help='kustomize binary (default: kustomize, else kubectl kustomize, on PATH)')
    args = parser.parse_args()
    os.chdir(REPO)
    tool = kustomize_tool(args.kustomize)

    # 1. Provider-neutral bases.
    for directory in NEUTRAL:
        try:
            found = scan_neutral(directory, PROVIDER_PATTERNS, [(k, n, d) for k, n, d, _ in EXEMPT if d == directory])
        except RenderError as err:
            check(False, '%s renders: %s' % (directory, err))
            continue
        check(not found, '%s is provider-neutral%s' % (directory, ''.join('\n    ' + f for f in found[:20])))
    for kind, name, directory, reason in EXEMPT:
        print('NOTE: %s: %s %s keeps a provider value: %s' % (directory, kind, name, reason))
    for directory, reason in PROVIDER_BOUND.items():
        print('NOTE: %s is provider-bound: %s' % (directory, reason))

    # 2. Every entry point renders, through the overlay that holds the provider pieces.
    for current, _ in ENTRY_POINTS:
        try:
            render(current)
            check(True, '%s renders (built-in renderer)' % current)
        except RenderError as err:
            check(False, '%s renders (built-in renderer): %s' % (current, err))
        if tool:
            try:
                kustomize_render(tool, current)
                check(True, '%s renders (%s)' % (current, ' '.join(tool)))
            except RenderError as err:
                check(False, str(err))
    extra_checks(check)

    # 3. Equivalence with a baseline commit: the same objects (built-in renderer), the same bytes
    # (kustomize, when present).
    if args.baseline:
        tmp = tempfile.mkdtemp(prefix='provider-overlays-')
        try:
            extract(args.baseline, ARCHIVE_PATHS, tmp)
            for current, before in ENTRY_POINTS:
                old_dir = os.path.join(tmp, before)
                label = '%s (now) = %s at %s' % (current, before, args.baseline)
                if not os.path.isdir(old_dir):
                    check(False, '%s: %s does not exist at the baseline' % (label, before))
                    continue
                try:
                    old, new = render(old_dir), render(current)
                except RenderError as err:
                    check(False, '%s: %s' % (label, err))
                    continue
                check(old == new, '%s: the same %d objects%s' % (label, len(new), '' if old == new else '\n' + describe_diff(old, new)))
                if tool:
                    a, b = kustomize_render(tool, old_dir), kustomize_render(tool, current)
                    check(a == b, '%s: kustomize output byte-identical (%d bytes)%s' % (label, len(b), '' if a == b else '\n' + '\n'.join(
                        list(difflib.unified_diff(a.splitlines(), b.splitlines(), 'baseline', 'now', lineterm=''))[:60])))
            if not tool:
                print('SKIP: no kustomize or kubectl on PATH: the byte-for-byte kustomize comparison did not run')
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    else:
        print('SKIP: no --baseline given: the equivalence with a baseline commit did not run')

    print('%d failure(s)' % len(FAILURES))
    return 1 if FAILURES else 0


if __name__ == '__main__':
    sys.exit(main())
