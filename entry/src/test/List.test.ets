import localUnitTest from './LocalUnit.test';
import loggerTest from './Logger.test';
import sshErrorTest from './SshError.test';

export default function testsuite() {
  localUnitTest();
  loggerTest();
  sshErrorTest();
}
