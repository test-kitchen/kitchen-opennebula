## 0.3.0

* fix endless loop in passwordless sudo check
* wait for cloud-init to complete successfully

## 0.2.3

* add random string to instance name
* allow specifying cpu for box
* use documented ONE_AUTH key
* keep lower bound of requirement to '>= 4.10'

## 0.2.2

* Restrict opennebula gem dependency version to be '~> 4.10', '< 5'.

## 0.2.1

* Do not use methods from Kitchen::SSHBase as we are no longer inherit them. Rely on instance.transport instead.

## 0.2.0

* Switch SSH api to use gateway-enabled wrapper, instead of raw Kitchen::SSH, which does not support ssh gateways.

## 0.1.2

* Adds an authentication check for OpenNebula, and uses a later version of fog which supports multiple NICs in a VM template.

## 0.1.0

* Initial release
