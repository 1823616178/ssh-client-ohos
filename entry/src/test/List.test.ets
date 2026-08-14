import localUnitTest from './LocalUnit.test';
import loggerTest from './Logger.test';
import modelTest from './Model.test';
import settingsRepositoryTest from './SettingsRepository.test';
import sshErrorTest from './SshError.test';
import sshTerminalTest from './SshTerminal.test';
import terminalRenderTest from './TerminalRender.test';
import frameSchedulerTest from './FrameScheduler.test';
import fontServiceTest from './FontService.test';
import keyMapTest, { focusManagerTest } from './KeyMap.test';
import stickyModifiersTest from './StickyModifiers.test';
import imeInputTest from './ImeInput.test';

export default function testsuite() {
  localUnitTest();
  loggerTest();
  modelTest();
  settingsRepositoryTest();
  sshErrorTest();
  sshTerminalTest();
  terminalRenderTest();
  frameSchedulerTest();
  fontServiceTest();
  keyMapTest();
  focusManagerTest();
  stickyModifiersTest();
  imeInputTest();
}
