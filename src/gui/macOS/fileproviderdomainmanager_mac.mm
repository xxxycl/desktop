/*
 * Copyright (C) 2022 by Claudio Cambra <claudio.cambra@nextcloud.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 * or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
 * for more details.
 */

#include "fileproviderdomainmanager.h"
#include "pushnotifications.h"

#import <FileProvider/FileProvider.h>

#include <QLoggingCategory>

#include "gui/accountmanager.h"
#include "gui/accountstate.h"
#include "libsync/account.h"

namespace OCC {

Q_LOGGING_CATEGORY(lcMacFileProviderDomainManager, "nextcloud.gui.macfileproviderdomainmanager", QtInfoMsg)

namespace Mac {

FileProviderDomainManager *FileProviderDomainManager::_instance = nullptr;

class FileProviderDomainManager::Private {

  public:
    Private() = default;
    ~Private() = default;

    void findExistingFileProviderDomains()
    {
        [NSFileProviderManager getDomainsWithCompletionHandler:^(NSArray<NSFileProviderDomain *> *domains, NSError *error) {
            if(error) {
                qCDebug(lcMacFileProviderDomainManager) << "Could not get existing file provider domains: "
                                                        << error.code
                                                        << error.localizedDescription;
            }

            for (NSFileProviderDomain *domain in domains) {
                const auto accountId = QString::fromNSString(domain.identifier);

                if (const auto accountState = AccountManager::instance()->accountFromUserId(accountId);
                        accountState &&
                        accountState->account() &&
                        accountState->account()->displayName() == QString::fromNSString(domain.displayName)) {

                    qCDebug(lcMacFileProviderDomainManager) << "Found existing file provider domain for account:"
                                                            << accountState->account()->displayName();
                    _registeredDomains.insert(accountId, domain);

                } else {
                    qCDebug(lcMacFileProviderDomainManager) << "Found existing file provider domain with no known configured account:"
                                                            << domain.displayName;
                    [NSFileProviderManager removeDomain:domain completionHandler:^(NSError *error) {
                        if(error) {
                            qCDebug(lcMacFileProviderDomainManager) << "Error removing file provider domain: "
                                                                    << error.code
                                                                    << error.localizedDescription;
                        }
                    }];
                }
            }
        }];
    }

    void addFileProviderDomain(const AccountState *accountState)
    {
        const auto accountDisplayName = accountState->account()->displayName();
        const auto accountId = accountState->account()->userIdAtHostWithPort();

        qCDebug(lcMacFileProviderDomainManager) << "Adding new file provider domain for account with id: " << accountId;

        if(_registeredDomains.contains(accountId) && _registeredDomains.value(accountId) != nil) {
            qCDebug(lcMacFileProviderDomainManager) << "File provider domain for account with id already exists: " << accountId;
            return;
        }

        NSFileProviderDomain *fileProviderDomain = [[NSFileProviderDomain alloc] initWithIdentifier:accountId.toNSString()
                                                                                        displayName:accountDisplayName.toNSString()];
        [NSFileProviderManager addDomain:fileProviderDomain completionHandler:^(NSError *error) {
            if(error) {
                qCDebug(lcMacFileProviderDomainManager) << "Error adding file provider domain: "
                                                        << [error code]
                                                        << [error localizedDescription];
            }
        }];

        _registeredDomains.insert(accountId, fileProviderDomain);
    }

    void removeFileProviderDomain(const AccountState *accountState)
    {
        const auto accountId = accountState->account()->userIdAtHostWithPort();
        qCDebug(lcMacFileProviderDomainManager) << "Removing file provider domain for account with id: " << accountId;

        if(!_registeredDomains.contains(accountId)) {
            qCDebug(lcMacFileProviderDomainManager) << "File provider domain not found for id: " << accountId;
            return;
        }

        NSFileProviderDomain* fileProviderDomain = _registeredDomains[accountId];

        [NSFileProviderManager removeDomain:fileProviderDomain completionHandler:^(NSError *error) {
            if(error) {
                qCDebug(lcMacFileProviderDomainManager) << "Error removing file provider domain: "
                                                        << [error code]
                                                        << [error localizedDescription];
            }
        }];

        NSFileProviderDomain* domain = _registeredDomains.take(accountId);
        [domain release];
    }

    void removeAllFileProviderDomains()
    {
        qCDebug(lcMacFileProviderDomainManager) << "Removing all file provider domains.";

        [NSFileProviderManager removeAllDomainsWithCompletionHandler:^(NSError *error) {
            if(error) {
                qCDebug(lcMacFileProviderDomainManager) << "Error removing all file provider domains: "
                                                        << [error code]
                                                        << [error localizedDescription];
            }
        }];
    }

    void wipeAllFileProviderDomains()
    {
        qCDebug(lcMacFileProviderDomainManager) << "Removing and wiping all file provider domains";

        [NSFileProviderManager getDomainsWithCompletionHandler:^(NSArray<NSFileProviderDomain *> *domains, NSError *error) {
            if (error) {
                qCDebug(lcMacFileProviderDomainManager) << "Error removing and wiping file provider domains: "
                                                        << [error code]
                                                        << [error localizedDescription];
                return;
            }

            for (NSFileProviderDomain *domain in domains) {
                [NSFileProviderManager removeDomain:domain mode:NSFileProviderDomainRemovalModeRemoveAll completionHandler:^(NSURL *preservedLocation, NSError *error) {
                    if (error) {
                        qCDebug(lcMacFileProviderDomainManager) << "Error removing and wiping file provider domain: "
                                                                << [domain displayName]
                                                                << [error code]
                                                                << [error localizedDescription];
                        return;
                    }
                }];
            }
        }];
    }

    void signalEnumeratorChanged(const Account * const account)
    {
        const auto accountId = account->userIdAtHostWithPort();
        qCDebug(lcMacFileProviderDomainManager) << "Signalling enumerator changed in file provider domain for account with id: " << accountId;

        if(!_registeredDomains.contains(accountId)) {
            qCDebug(lcMacFileProviderDomainManager) << "File provider domain not found for id: " << accountId;
            return;
        }

        NSFileProviderDomain * const fileProviderDomain = _registeredDomains[accountId];
        NSFileProviderManager * const fpManager = [NSFileProviderManager managerForDomain:fileProviderDomain];
        [fpManager signalEnumeratorForContainerItemIdentifier:NSFileProviderWorkingSetContainerItemIdentifier completionHandler:^(NSError *error) {
            if (error != nil) {
                qCDebug(lcMacFileProviderDomainManager) << "Error signalling enumerator changed for working set:"
                                                        << error.localizedDescription;
            }
        }];
    }

private:
    QHash<QString, NSFileProviderDomain*> _registeredDomains;
};

FileProviderDomainManager::FileProviderDomainManager(QObject *parent)
    : QObject(parent)
{
    d.reset(new FileProviderDomainManager::Private());

    d->findExistingFileProviderDomains();

    connect(AccountManager::instance(), &AccountManager::accountAdded,
            this, &FileProviderDomainManager::addFileProviderDomainForAccount);
    connect(AccountManager::instance(), &AccountManager::accountRemoved,
            this, &FileProviderDomainManager::removeFileProviderDomainForAccount);

    setupFileProviderDomains(); // Initially fetch accounts in manager
}

FileProviderDomainManager *FileProviderDomainManager::instance()
{
    if (!_instance) {
        _instance = new FileProviderDomainManager();
    }
    return _instance;
}

FileProviderDomainManager::~FileProviderDomainManager() = default;

void FileProviderDomainManager::setupFileProviderDomains()
{
    for(auto &accountState : AccountManager::instance()->accounts()) {
        addFileProviderDomainForAccount(accountState.data());
    }
}

void FileProviderDomainManager::addFileProviderDomainForAccount(AccountState *accountState)
{
    Q_ASSERT(accountState);
    const auto account = accountState->account();
    Q_ASSERT(account);

    d->addFileProviderDomain(accountState);

    const auto accountCapabilities = account->capabilities().isValid();
    if (!accountCapabilities) {
        connect(account.get(), &Account::capabilitiesChanged, this, [this, account] {
            trySetupPushNotificationsForAccount(account.get());
        });
        return;
    }

    trySetupPushNotificationsForAccount(account.get());
}

void FileProviderDomainManager::trySetupPushNotificationsForAccount(Account *account)
{
    Q_ASSERT(account);

    const auto pushNotifications = account->pushNotifications();
    const auto pushNotificationsCapability = account->capabilities().availablePushNotifications() & PushNotificationType::Files;

    if (pushNotificationsCapability && pushNotifications && pushNotifications->isReady()) {
        qCDebug(lcMacFileProviderDomainManager) << "Push notifications already ready, connecting them to enumerator signalling."
                                                << account->displayName();
        setupPushNotificationsForAccount(account);
    } else if (pushNotificationsCapability) {
        qCDebug(lcMacFileProviderDomainManager) << "Push notifications not yet ready, will connect to signalling when ready."
                                                << account->displayName();
        connect(account, &Account::pushNotificationsReady, this, &FileProviderDomainManager::setupPushNotificationsForAccount);
    }
}

void FileProviderDomainManager::setupPushNotificationsForAccount(Account *account)
{
    Q_ASSERT(account);

    qCDebug(lcMacFileProviderDomainManager) << "Setting up push notifications for file provider domain for account:"
                                            << account->displayName();

    connect(account->pushNotifications(), &PushNotifications::filesChanged, this, &FileProviderDomainManager::signalEnumeratorChanged);
    disconnect(account, &Account::pushNotificationsReady, this, &FileProviderDomainManager::setupPushNotificationsForAccount);
}

void FileProviderDomainManager::signalEnumeratorChanged(Account *account)
{
    Q_ASSERT(account);
    d->signalEnumeratorChanged(account);
}

void FileProviderDomainManager::removeFileProviderDomainForAccount(AccountState* accountState)
{
    Q_ASSERT(accountState);
    const auto account = accountState->account();
    Q_ASSERT(account);

    d->removeFileProviderDomain(accountState);

    const auto pushNotifications = account->pushNotifications();
    const auto pushNotificationsCapability = account->capabilities().availablePushNotifications() & PushNotificationType::Files;

    if (pushNotificationsCapability && pushNotifications && pushNotifications->isReady()) {
        disconnect(pushNotifications, &PushNotifications::filesChanged, this, &FileProviderDomainManager::signalEnumeratorChanged);
    } else if (pushNotificationsCapability) {
        disconnect(account.get(), &Account::pushNotificationsReady, this, &FileProviderDomainManager::setupPushNotificationsForAccount);
    }
}

} // namespace Mac

} // namespace OCC
