import re
import pathlib

root = pathlib.Path(r'C:\Users\lx182\DevEcoStudioProjects\ssh_client_ohos\entry\src\main\ets')
patterns = {
    'ALLCAPS': re.compile(r"Text\('[A-Z][A-Z ]{3,}'\)"),
    'transparent': re.compile(r'Color\.Transparent'),
    'white': re.compile(r'Color\.White'),
    'native_channel_ui': re.compile(r"Text\('native channel"),
    'napi_ui': re.compile(r"Text\('.*NAPI|Text\('SFTP native"),
    'back_hint': re.compile(r'返回提示'),
    'residual_ui': re.compile(r"Text\('.*residual"),
    'U4_ui': re.compile(r"Text\('.*U4"),
    'font9': re.compile(r'fontSize\(9\)'),
    'font28': re.compile(r'fontSize\(28\)'),
}
owned = [
    'PageHeader.ets', 'Index.ets', 'AppearancePage.ets', 'KeyManagerPage.ets',
    'ConfigManagerPage.ets', 'OpenSourceLicensesPage.ets', 'SftpPage.ets',
    'PortForwardPage.ets', 'SettingsPage.ets', 'AccountSyncPage.ets',
    'HostEditPage.ets', 'TerminalPage.ets', 'TerminalPaneEmbed.ets',
]
for name in owned:
    paths = list(root.rglob(name))
    if not paths:
        print('MISSING', name)
        continue
    text = paths[0].read_text(encoding='utf-8')
    hits = []
    for key, pat in patterns.items():
        if pat.search(text):
            hits.append(key)
            for i, line in enumerate(text.splitlines(), 1):
                if pat.search(line):
                    print(f'{name}:{i} [{key}] {line.strip()[:140]}')
    if not hits:
        print('OK', name)
