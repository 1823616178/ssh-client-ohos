import localUnitTest from './LocalUnit.test';
import loggerTest from './Logger.test';
import modelTest from './Model.test';
import settingsRepositoryTest from './SettingsRepository.test';
import sshErrorTest from './SshError.test';
import sshTerminalTest from './SshTerminal.test';

export default function testsuite() {
  localUnitTest();
  loggerTest();
  modelTest();
  settingsRepositoryTest();
  sshErrorTest();
  sshTerminalTest();
}
